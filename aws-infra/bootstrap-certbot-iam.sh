#!/usr/bin/env bash
# One-time bootstrap: create the `honeybot-certbot` IAM user scoped to
# Route53 changes on the honeymanenterprises.com hosted zone.
#
# Run from a machine with admin AWS creds (your laptop, with `op signin`
# active so we can pull the admin key — or just use your regular profile).
#
# Outputs: a new access key pair. File it into 1Password immediately at
#   op://Honeybot/Certbot AWS/access_key_id
#   op://Honeybot/Certbot AWS/secret_access_key
#   op://Honeybot/Certbot AWS/default_region     (set to us-east-1)
set -euo pipefail

USER_NAME="honeybot-certbot"
POLICY_NAME="honeybot-certbot-route53"
ZONE_NAME="honeymanenterprises.com."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="${SCRIPT_DIR}/iam-certbot-policy.json"

echo ">>> Looking up hosted zone ID for ${ZONE_NAME} ..."
ZONE_ID_RAW="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${ZONE_NAME}" \
  --max-items 1 \
  --query 'HostedZones[0].Id' \
  --output text)"
# API returns "/hostedzone/XYZ" — policy wants just "XYZ".
ZONE_ID="${ZONE_ID_RAW##*/}"
if [[ -z "${ZONE_ID}" || "${ZONE_ID}" == "None" ]]; then
  echo "ERROR: hosted zone ${ZONE_NAME} not found in this account." >&2
  exit 1
fi
echo "    Hosted zone ID: ${ZONE_ID}"

# Materialize the policy with the real zone ID substituted.
RENDERED_POLICY="$(mktemp)"
trap 'rm -f "${RENDERED_POLICY}"' EXIT
sed "s|REPLACE_WITH_ZONE_ID|${ZONE_ID}|g" "${POLICY_FILE}" > "${RENDERED_POLICY}"

echo ">>> Ensuring IAM user ${USER_NAME} exists ..."
if aws iam get-user --user-name "${USER_NAME}" >/dev/null 2>&1; then
  echo "    User ${USER_NAME} already exists."
else
  aws iam create-user --user-name "${USER_NAME}" >/dev/null
  echo "    Created user ${USER_NAME}."
fi

echo ">>> Ensuring inline policy ${POLICY_NAME} is attached ..."
aws iam put-user-policy \
  --user-name "${USER_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "file://${RENDERED_POLICY}"
echo "    Policy attached."

# Rotate: if the user already has 2 keys, we can't create another. Print
# what's there so the human can decide whether to delete an old one.
EXISTING_KEYS="$(aws iam list-access-keys \
  --user-name "${USER_NAME}" \
  --query 'length(AccessKeyMetadata)' \
  --output text)"
if [[ "${EXISTING_KEYS}" -ge 2 ]]; then
  echo "WARNING: ${USER_NAME} already has ${EXISTING_KEYS} access keys (IAM limit is 2)."
  echo "         Delete an old one before re-running this script:"
  aws iam list-access-keys --user-name "${USER_NAME}" \
    --query 'AccessKeyMetadata[].{Id:AccessKeyId,Created:CreateDate}' --output table
  exit 1
fi

echo ">>> Creating access key ..."
KEY_JSON="$(aws iam create-access-key --user-name "${USER_NAME}")"
AKID="$(echo "${KEY_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
SECRET="$(echo "${KEY_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"

cat <<EOF

================================================================================
  certbot IAM credentials created. File these into 1Password NOW — this is the
  ONLY time the secret will be shown.

    op://Honeybot/Certbot AWS/access_key_id      = ${AKID}
    op://Honeybot/Certbot AWS/secret_access_key  = ${SECRET}
    op://Honeybot/Certbot AWS/default_region     = us-east-1

  To file via CLI:
    op item edit "Certbot AWS" --vault Honeybot \\
      "access_key_id=${AKID}" \\
      "secret_access_key=${SECRET}" \\
      "default_region=us-east-1"

  (Create the item first with \`op item create --category=apicredential ...\`
   if it doesn't exist.)
================================================================================
EOF
