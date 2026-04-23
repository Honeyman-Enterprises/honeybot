#!/usr/bin/env bash
# Phase 1 bring-up orchestrator.
#
# Idempotent. Runs all of Phase 1 in order, with preflight checks between
# steps, on the EC2 host. Safe to re-run.
#
# Prereqs (fail fast if missing):
#   1. PR #3 (Phase 0 scaffold) merged to main
#   2. op.env present at repo root with OP_SERVICE_ACCOUNT_TOKEN
#      (scoped to the Honeybot vault with read_items + write_items).
#      Item creation in that vault is handled by scripts/seed-vault.sh
#      which runs INSIDE the honeybot container on every boot.
#   3. Docker + docker compose installed, daemon running
#   4. git clean on main at latest origin/main
#   5. Port 80 reachable from the public internet on the EC2's EIP so
#      Let's Encrypt's HTTP-01 validators can hit
#      /.well-known/acme-challenge/<token>. No AWS cert, no IAM cert
#      permissions required — LE is entirely out-of-band of AWS.
#
# What it does:
#   1. `docker compose build` new service images (nginx, honeybot, ES, Neo4j)
#   2. Upserts Route53 records pointing at this EC2's public IP
#   3. Installs the EBS DLM snapshot policy
#   4. Starts the full stack. The honeybot container seeds any missing
#      1Password items via seed-vault.sh before varlock resolves the schema.
#   5. Waits for health, reports status
#
# NOTE on certs: we no longer run certbot. TLS certs are issued + renewed
# in-process by lua-resty-acme against Let's Encrypt (HTTP-01 challenge)
# — see ./nginx/Dockerfile + ./nginx/nginx.conf. No certbot binary, no
# sidecar, no cron, no Route53 DNS-01. First HTTPS handshake for each
# whitelisted domain triggers issuance; renewals fire 30d before expiry.
#
# NOTE on crons: no host-level crons. Route53 IP refresh is not needed
# (the EC2 has an Elastic IP). Any recurring work runs inside a container
# — either the main honeybot process (via Hermes' cron support) or a
# dedicated sidecar container.
#
# Abort semantics: any step failure halts the script. Re-running after
# fixing the cause picks up where it left off (each step is idempotent).
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${REPO_DIR}"

# ---- Preflight --------------------------------------------------------------
echo "=== phase-1-bringup: preflight ==="

if [[ ! -f op.env ]]; then
  echo "ERROR: op.env missing at ${REPO_DIR}/op.env" >&2
  echo "       Should contain: OP_SERVICE_ACCOUNT_TOKEN=..." >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not installed" >&2; exit 2
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose plugin not installed" >&2; exit 2
fi

# Load OP_SERVICE_ACCOUNT_TOKEN from op.env so Route53 / DLM scripts can
# authenticate against 1Password too. Vault item seeding itself runs inside
# the honeybot container — we do NOT probe for specific items here.
# shellcheck disable=SC1091
set -a; source op.env; set +a
if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  echo "ERROR: OP_SERVICE_ACCOUNT_TOKEN not set from op.env" >&2
  exit 2
fi

# ---- Step 1: build new service images --------------------------------------
echo "=== phase-1-bringup: building images ==="
docker compose build nginx honeybot

# ---- Step 2: Route53 upsert -------------------------------------------------
echo "=== phase-1-bringup: upserting Route53 records ==="
# route53-upsert.sh uses varlock internally to resolve AWS creds from 1P.
# If varlock isn't on the host, the script is responsible for bailing out
# with a clear message — this orchestrator just invokes it.
./aws-infra/route53-upsert.sh

# ---- Step 3: EBS DLM policy + volume tag ------------------------------------
echo "=== phase-1-bringup: ensuring EBS DLM policy ==="
./aws-infra/ebs-dlm-snapshot-policy.sh

echo ""
echo "NOTE: If this is the first bring-up, you still need to TAG the Docker"
echo "      data volume so the DLM policy targets it. See the command printed"
echo "      by ebs-dlm-snapshot-policy.sh above. Re-running this script after"
echo "      tagging is safe."
echo ""

# ---- Step 4: bring up the stack --------------------------------------------
# Bring-up flow (orchestrated by compose via depends_on):
#
#   secrets-init (one-shot) runs FIRST:
#     - seed-vault.sh creates any missing 1Password items (empty placeholders
#       for human-filled creds; auto-generated passwords for internal svcs
#       like Elasticsearch + Neo4j).
#     - emit-runtime-env.sh writes ./.env.runtime (chmod 600) with the
#       values ES + Neo4j need, read fresh from 1Password.
#   secrets-init exits 0 → elasticsearch, neo4j, honeybot start in parallel.
#
# Humans still need to fill @required items (Anthropic, Slack, AWS, Mem0)
# via the 1Password UI. The honeybot container's varlock step fails closed
# on next boot until they're populated.
echo "=== phase-1-bringup: starting stack (secrets-init → nginx + honeybot + elasticsearch + neo4j) ==="
docker compose up -d nginx honeybot elasticsearch neo4j

# ---- Step 5: healthchecks ---------------------------------------------------
echo "=== phase-1-bringup: waiting for health ==="
sleep 15

# nginx healthz (only reachable from the host via localhost:80/healthz)
if curl -fsS http://127.0.0.1/healthz >/dev/null 2>&1; then
  echo "  nginx:         OK"
else
  echo "  nginx:         FAIL (curl http://127.0.0.1/healthz)"
fi

# HTTPS should serve with a Let's Encrypt cert. First request per domain
# may stall 2-5s while lua-resty-acme completes HTTP-01 issuance against
# LE; retry with -m 30 so the first call doesn't false-negative.
if curl -fsS -m 30 https://honeybot.honeymanenterprises.com/healthz >/dev/null 2>&1; then
  echo "  https (apex):  OK"
else
  echo "  https (apex):  FAIL — check DNS, SG :80 inbound, nginx logs for ACME"
fi

# ES — from inside the honeynet network; exec into a sidecar alpine.
# Password is read from 1P via op; the service account token is already in env.
if docker run --rm --network honeybot_honeynet \
     -e OP_SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN}" \
     1password/op:2 sh -c '
       pw="$(op read op://Honeybot/Elasticsearch/password)"
       apk add --no-cache curl >/dev/null
       curl -fsS -u "elastic:${pw}" http://elasticsearch:9200/_cluster/health
     ' 2>/dev/null | grep -q "status"; then
  echo "  elasticsearch: OK"
else
  echo "  elasticsearch: FAIL"
fi

# Neo4j — bolt is on 7687. Just check the port is listening.
if docker run --rm --network honeybot_honeynet alpine:3.20 \
     sh -c "nc -z neo4j 7687"; then
  echo "  neo4j:         OK"
else
  echo "  neo4j:         FAIL"
fi

echo ""
echo "=== phase-1-bringup: done ==="
echo ""
echo "Next steps:"
echo "  - Populate any empty @required 1Password items (Anthropic, Slack,"
echo "    Mem0, AWS) via the 1Password web UI. The honeybot container will"
echo "    fail closed until they're filled."
echo "  - On first HTTPS hit per domain, lua-resty-acme will issue a cert"
echo "    against Let's Encrypt (2-5s stall). Renewals happen in-process"
echo "    30d before expiry; no cron needed."
echo "  - Proceed to Phase 2 (Hermes webhook platform + Retell wiring)."
