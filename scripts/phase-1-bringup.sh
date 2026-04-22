#!/usr/bin/env bash
# Phase 1 bring-up orchestrator.
#
# Idempotent. Runs all of Phase 1 in order, with preflight checks between
# steps, on the EC2 host. Safe to re-run.
#
# Prereqs (fail fast if missing):
#   1. PR #3 (Phase 0 scaffold) merged to main
#   2. 1Password items populated:
#      - Honeybot/Certbot        (email)
#      - Honeybot/Elasticsearch  (password)
#      - Honeybot/Neo4j          (auth, format "neo4j/<password>")
#   3. Certbot AWS IAM user created via bootstrap-certbot-iam.sh
#      and its creds filed at Honeybot/Certbot AWS/*
#   4. op.env present at repo root with OP_SERVICE_ACCOUNT_TOKEN
#   5. Docker + docker compose installed, daemon running
#   6. git clean on main at latest origin/main
#
# What it does:
#   1. `docker compose build` new services (nginx, certbot, ES, Neo4j)
#   2. Upserts Route53 records pointing at this EC2's public IP
#   3. Installs the EBS DLM snapshot policy
#   4. Starts certbot FIRST (in staging mode) to verify cert issuance
#      against LE staging — avoids burning prod rate limits
#   5. Stops certbot, flips CERTBOT_STAGING off, re-runs for prod cert
#   6. Starts nginx, elasticsearch, neo4j
#   7. Waits for health, reports status
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
if ! command -v varlock >/dev/null 2>&1; then
  echo "ERROR: varlock not installed on host. Install with: npm i -g varlock" >&2
  exit 2
fi

# Validate vault items that MUST exist before we do anything cert-related.
echo "=== phase-1-bringup: checking 1Password items ==="
required_vault_paths=(
  "op://Honeybot/Certbot AWS/access_key_id"
  "op://Honeybot/Certbot AWS/secret_access_key"
  "op://Honeybot/Certbot AWS/default_region"
  "op://Honeybot/Certbot/email"
  "op://Honeybot/Elasticsearch/password"
  "op://Honeybot/Neo4j/auth"
)

# Load OP_SERVICE_ACCOUNT_TOKEN from op.env for the preflight check.
# shellcheck disable=SC1091
set -a; source op.env; set +a
if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  echo "ERROR: OP_SERVICE_ACCOUNT_TOKEN not set from op.env" >&2
  exit 2
fi

missing=0
for path in "${required_vault_paths[@]}"; do
  if ! op read "${path}" >/dev/null 2>&1; then
    echo "  MISSING: ${path}"
    missing=1
  else
    echo "  OK:      ${path}"
  fi
done
if [[ ${missing} -ne 0 ]]; then
  echo "ERROR: populate the missing 1Password items before continuing." >&2
  echo "       See docs/phase-0-infra.md for the full list and formats." >&2
  exit 3
fi

# ---- Step 1: build new service images --------------------------------------
echo "=== phase-1-bringup: building images ==="
docker compose build nginx certbot

# ---- Step 2: Route53 upsert -------------------------------------------------
echo "=== phase-1-bringup: upserting Route53 records ==="
varlock run -- ./aws-infra/route53-upsert.sh

# ---- Step 3: EBS DLM policy + volume tag ------------------------------------
echo "=== phase-1-bringup: ensuring EBS DLM policy ==="
varlock run -- ./aws-infra/ebs-dlm-snapshot-policy.sh

echo ""
echo "NOTE: If this is the first bring-up, you still need to TAG the Docker"
echo "      data volume so the DLM policy targets it. See the command printed"
echo "      by ebs-dlm-snapshot-policy.sh above. Re-running this script after"
echo "      tagging is safe."
echo ""

# ---- Step 4: certbot in LE STAGING mode ------------------------------------
#
# Why: LE production has a 5-cert-per-7-days rate limit per registered
# domain. We verify the full DNS-01 flow against staging first, then
# flip to prod exactly once.
echo "=== phase-1-bringup: issuing cert against LE STAGING ==="
export CERTBOT_STAGING=1
docker compose up -d --force-recreate certbot
echo "    waiting up to 180s for staging cert ..."

# Poll the cert volume for a fullchain.pem landing.
deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < deadline )); do
  if docker compose exec -T certbot test -f /etc/letsencrypt/live/honeybot.honeymanenterprises.com/fullchain.pem 2>/dev/null; then
    echo "    staging cert issued."
    break
  fi
  sleep 5
done
if ! docker compose exec -T certbot test -f /etc/letsencrypt/live/honeybot.honeymanenterprises.com/fullchain.pem 2>/dev/null; then
  echo "ERROR: staging cert did not issue within 180s. Check logs:" >&2
  echo "       docker compose logs certbot --tail=100" >&2
  exit 4
fi

# ---- Step 5: wipe staging cert + issue prod cert ----------------------------
echo "=== phase-1-bringup: issuing PRODUCTION cert ==="
docker compose stop certbot
# Remove the staging cert directory so certbot treats this as a fresh issue.
docker run --rm \
  -v honeybot_certbot-etc:/etc/letsencrypt \
  alpine:3.20 \
  sh -c 'rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal'
unset CERTBOT_STAGING
# Rewrite the env file for this invocation only. `docker compose` reads env
# from the shell, so unsetting here is enough.
docker compose up -d --force-recreate certbot
echo "    waiting up to 180s for prod cert ..."

deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < deadline )); do
  if docker compose exec -T certbot test -f /etc/letsencrypt/live/honeybot.honeymanenterprises.com/fullchain.pem 2>/dev/null; then
    echo "    prod cert issued."
    break
  fi
  sleep 5
done
if ! docker compose exec -T certbot test -f /etc/letsencrypt/live/honeybot.honeymanenterprises.com/fullchain.pem 2>/dev/null; then
  echo "ERROR: prod cert did not issue within 180s. Check logs:" >&2
  exit 4
fi

# ---- Step 6: bring up the rest ----------------------------------------------
echo "=== phase-1-bringup: starting nginx + elasticsearch + neo4j ==="
docker compose up -d nginx elasticsearch neo4j

# ---- Step 7: healthchecks ---------------------------------------------------
echo "=== phase-1-bringup: waiting for health ==="
sleep 15

# nginx healthz (only reachable from the host via localhost:80/healthz)
if curl -fsS http://127.0.0.1/healthz >/dev/null 2>&1; then
  echo "  nginx:         OK"
else
  echo "  nginx:         FAIL (curl http://127.0.0.1/healthz)"
fi

# HTTPS should serve with the prod cert now.
if curl -fsS https://honeybot.honeymanenterprises.com/healthz >/dev/null 2>&1; then
  echo "  https (apex):  OK"
else
  echo "  https (apex):  FAIL — check DNS propagation + nginx logs"
fi

# ES — from inside the honeynet network; exec into a sidecar alpine.
if docker run --rm --network honeybot_honeynet alpine:3.20 \
     sh -c "wget -qO- --user=elastic --password=\"$(op read 'op://Honeybot/Elasticsearch/password')\" http://elasticsearch:9200/_cluster/health" | grep -q "status"; then
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
echo "  - Install the daily cron for Route53 re-upsert (in case EC2 restarts"
echo "    and gets a new public IP):"
echo "      scripts/install-phase-1-crons.sh"
echo "  - Proceed to Phase 2 (Hermes webhook platform + Retell wiring)."
