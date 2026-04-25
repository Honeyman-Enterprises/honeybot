#!/usr/bin/env bash
# Phase 1 bring-up — thin host-side wrapper.
#
# Most of what used to live here moved into the `secrets-init` compose
# service, which runs as a one-shot on every `docker compose up` and is
# itself idempotent:
#   - seed-vault.sh         → idempotent 1Password vault item creation
#   - emit-runtime-env.sh   → writes ./.env.runtime for ES + Neo4j env_file
#   - ensure-aws-infra.sh   → idempotent EBS DLM policy + volume tag
#                             (no-ops on laptops without honeybot-prod tag)
#
# This script's job is now narrow: preflight the host, bring up the stack,
# wait for health. Safe to re-run.
#
# Prereqs:
#   1. op.env at the repo root with OP_SERVICE_ACCOUNT_TOKEN
#      (scoped to the Honeybot vault with read_items + write_items).
#   2. Docker + docker compose installed, daemon running.
#   3. EC2 instance tagged Name=honeybot-prod (or HONEYBOT_INSTANCE_TAG).
#      Without this tag, ensure-aws-infra.sh skips silently — the stack
#      still comes up, but DLM snapshots won't target the volume.
#   4. Route53 apex record (honeybot.honeymanenterprises.com → EIP) created
#      manually in the AWS console. No automation here.
#   5. Port 80 reachable from the public internet on the EC2's EIP so
#      Let's Encrypt's HTTP-01 validators can hit
#      /.well-known/acme-challenge/<token>.
#
# NOTE on certs: TLS certs are issued + renewed in-process by
# lua-resty-acme against Let's Encrypt (HTTP-01) inside the nginx
# container. No certbot, no sidecar, no cron. First HTTPS handshake per
# whitelisted domain triggers issuance; renewals fire 30d before expiry.
#
# NOTE on crons: no host-level crons. Recurring work runs inside a
# container — Hermes cron in the honeybot container or a dedicated sidecar.
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

# ---- Bring up the stack -----------------------------------------------------
# Compose orchestrates the order via depends_on: condition: service_completed_successfully:
#   secrets-init (one-shot) runs FIRST. It seeds 1Password, writes
#   .env.runtime, and ensures the AWS-side DLM policy + volume tag.
#   On exit 0, nginx + honeybot + elasticsearch + neo4j start in parallel.
#   If secrets-init fails, dependent services refuse to start (fail-closed).
echo "=== phase-1-bringup: docker compose up -d --build ==="
docker compose up -d --build nginx honeybot elasticsearch neo4j

# ---- Healthchecks -----------------------------------------------------------
echo "=== phase-1-bringup: waiting for health ==="
sleep 15

# nginx healthz (only reachable from the host via localhost:80/healthz)
if curl -fsS http://127.0.0.1/healthz >/dev/null 2>&1; then
  echo "  nginx:         OK"
else
  echo "  nginx:         FAIL (curl http://127.0.0.1/healthz)"
fi

# HTTPS should serve with a Let's Encrypt cert. First request per domain
# may stall 2-5s while lua-resty-acme completes HTTP-01 issuance; -m 30
# keeps the first call from false-negativing.
if curl -fsS -m 30 https://honeybot.honeymanenterprises.com/healthz >/dev/null 2>&1; then
  echo "  https (apex):  OK"
else
  echo "  https (apex):  FAIL — check DNS, SG :80 inbound, nginx logs for ACME"
fi

# ES — exec inside the honeynet network. Service account token is already
# loaded into the secrets-init container's env_file via op.env, so reuse it.
set -a; source op.env; set +a
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
echo "  - secrets-init logs (docker compose logs secrets-init) will show"
echo "    whether the EBS DLM policy + volume tag were ensured. First DLM"
echo "    snapshot fires within 24h of the volume being tagged."
