#!/usr/bin/env bash
# certbot entrypoint — first-run issue + periodic renew loop.
#
# Expects in env (via varlock):
#   AWS_ACCESS_KEY_ID       — IAM user scoped to Route53 change-resource-record-sets
#   AWS_SECRET_ACCESS_KEY
#   AWS_DEFAULT_REGION      — arbitrary, Route53 is a global service
#   CERTBOT_EMAIL           — admin email for LE notifications
#   CERTBOT_DOMAIN          — e.g. honeybot.honeymanenterprises.com
#   CERTBOT_WILDCARD_DOMAIN — e.g. *.honeybot.honeymanenterprises.com
#   CERTBOT_STAGING         — 1 for LE staging (recommended first run), empty for prod
set -euo pipefail

: "${CERTBOT_EMAIL:?required}"
: "${CERTBOT_DOMAIN:?required}"
: "${CERTBOT_WILDCARD_DOMAIN:?required}"

LIVE_DIR="/etc/letsencrypt/live/${CERTBOT_DOMAIN}"

args=(
  certonly
  --dns-route53
  --non-interactive
  --agree-tos
  --email "${CERTBOT_EMAIL}"
  -d "${CERTBOT_DOMAIN}"
  -d "${CERTBOT_WILDCARD_DOMAIN}"
  --preferred-challenges dns-01
  --keep-until-expiring
)

if [[ "${CERTBOT_STAGING:-}" == "1" ]]; then
  echo "certbot: using LE STAGING environment (test-only certs)"
  args+=(--test-cert)
fi

# First-run issue (only if no live cert exists).
if [[ ! -f "${LIVE_DIR}/fullchain.pem" ]]; then
  echo "certbot: no existing cert at ${LIVE_DIR}; issuing..."
  certbot "${args[@]}"
else
  echo "certbot: existing cert found at ${LIVE_DIR}; will renew on schedule"
fi

# Renew loop. Certbot's `renew` is a no-op if the cert has >30 days left,
# so running it every 12h is safe and idempotent.
while true; do
  sleep 43200   # 12h
  echo "certbot: running renewal check at $(date -Iseconds)"
  certbot renew --quiet \
    --deploy-hook "/usr/local/bin/renew.sh" || \
    echo "certbot: renew returned non-zero (will retry next cycle)"
done
