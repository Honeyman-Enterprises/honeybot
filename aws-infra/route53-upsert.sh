#!/usr/bin/env bash
# Upsert Route53 records for the honeybot subdomains.
#
# Records created:
#   honeybot.honeymanenterprises.com        A      -> EC2 public IP
#   hooks.honeybot.honeymanenterprises.com  CNAME  -> honeybot.honeymanenterprises.com
#   *.honeybot.honeymanenterprises.com      CNAME  -> honeybot.honeymanenterprises.com
#
# Idempotent — uses UPSERT so re-running updates in place.
#
# Must be run from the EC2 (reads its own public IP via instance metadata
# v2). For manual override, set HONEYBOT_PUBLIC_IP=1.2.3.4 in the env.
#
# Requires AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION
# in env — use `varlock run --` to pull them from 1Password.
set -euo pipefail

ZONE_NAME="honeymanenterprises.com."
APEX_FQDN="honeybot.honeymanenterprises.com"
HOOKS_FQDN="hooks.honeybot.honeymanenterprises.com"
WILDCARD_FQDN="*.honeybot.honeymanenterprises.com"
TTL=300

# --- Resolve EC2 public IP via IMDSv2 (or override via env) ------------------
if [[ -n "${HONEYBOT_PUBLIC_IP:-}" ]]; then
  PUBLIC_IP="${HONEYBOT_PUBLIC_IP}"
  echo "route53-upsert: using override IP ${PUBLIC_IP}"
else
  echo "route53-upsert: fetching EC2 public IP from IMDSv2 ..."
  IMDS_TOKEN="$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300")"
  PUBLIC_IP="$(curl -sS -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    http://169.254.169.254/latest/meta-data/public-ipv4)"
  if [[ -z "${PUBLIC_IP}" ]]; then
    echo "ERROR: unable to read EC2 public IP from IMDSv2." >&2
    exit 1
  fi
  echo "    Public IP: ${PUBLIC_IP}"
fi

# --- Look up hosted zone ID ---------------------------------------------------
ZONE_ID_RAW="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${ZONE_NAME}" \
  --max-items 1 \
  --query 'HostedZones[0].Id' \
  --output text)"
ZONE_ID="${ZONE_ID_RAW##*/}"
if [[ -z "${ZONE_ID}" || "${ZONE_ID}" == "None" ]]; then
  echo "ERROR: hosted zone ${ZONE_NAME} not found." >&2
  exit 1
fi
echo "route53-upsert: zone ${ZONE_ID}"

# --- Build change batch -------------------------------------------------------
BATCH="$(cat <<EOF
{
  "Comment": "honeybot subdomain records (idempotent upsert)",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${APEX_FQDN}",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [{"Value": "${PUBLIC_IP}"}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${HOOKS_FQDN}",
        "Type": "CNAME",
        "TTL": ${TTL},
        "ResourceRecords": [{"Value": "${APEX_FQDN}"}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${WILDCARD_FQDN}",
        "Type": "CNAME",
        "TTL": ${TTL},
        "ResourceRecords": [{"Value": "${APEX_FQDN}"}]
      }
    }
  ]
}
EOF
)"

TMP_BATCH="$(mktemp)"
trap 'rm -f "${TMP_BATCH}"' EXIT
echo "${BATCH}" > "${TMP_BATCH}"

CHANGE_ID_RAW="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "${ZONE_ID}" \
  --change-batch "file://${TMP_BATCH}" \
  --query 'ChangeInfo.Id' \
  --output text)"
echo "route53-upsert: submitted change ${CHANGE_ID_RAW}"
echo "route53-upsert: done"
