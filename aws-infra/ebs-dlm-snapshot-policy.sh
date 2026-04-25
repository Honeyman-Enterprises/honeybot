#!/usr/bin/env bash
# Create (or update) an EBS Data Lifecycle Manager policy that:
#   - Snapshots the Docker data volume(s) once every 24 hours
#   - Retains 7 snapshots (so 7 days at daily cadence)
#   - Targets volumes tagged Name=honeybot-docker-data
#
# Idempotent: reads existing policies by name; if one exists with the
# same identifier, updates it in place.
#
# Required: IAM role `AWSDataLifecycleManagerDefaultRole` (AWS-managed
# default for DLM). If this is the first DLM policy in the account, AWS
# creates the role automatically on first use via the console — from CLI
# we need to create it ourselves. This script does that if missing.
#
# Run once per account. Safe to re-run; it only changes things if the
# inputs changed.
set -euo pipefail

POLICY_DESCRIPTION="honeybot daily snapshot, 7-day retention"
POLICY_TAG_KEY="Name"
POLICY_TAG_VALUE="honeybot-docker-data"
DLM_ROLE_NAME="AWSDataLifecycleManagerDefaultRole"

# --- Ensure DLM service role exists ------------------------------------------
if ! aws iam get-role --role-name "${DLM_ROLE_NAME}" >/dev/null 2>&1; then
  echo "ebs-dlm: creating DLM service role ${DLM_ROLE_NAME} ..."
  TRUST_DOC='{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"dlm.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }'
  aws iam create-role \
    --role-name "${DLM_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_DOC}" >/dev/null
  aws iam attach-role-policy \
    --role-name "${DLM_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
  echo "    Role created."
else
  echo "ebs-dlm: DLM service role ${DLM_ROLE_NAME} already exists."
fi

DLM_ROLE_ARN="$(aws iam get-role --role-name "${DLM_ROLE_NAME}" \
  --query 'Role.Arn' --output text)"

# --- Build policy body --------------------------------------------------------
POLICY_DOC="$(cat <<EOF
{
  "ResourceTypes": ["VOLUME"],
  "TargetTags": [
    {"Key": "${POLICY_TAG_KEY}", "Value": "${POLICY_TAG_VALUE}"}
  ],
  "Schedules": [
    {
      "Name": "daily-7day",
      "CopyTags": true,
      "TagsToAdd": [
        {"Key": "CreatedBy", "Value": "honeybot-dlm"}
      ],
      "CreateRule": {
        "Interval": 24,
        "IntervalUnit": "HOURS",
        "Times": ["05:00"]
      },
      "RetainRule": {
        "Count": 7
      }
    }
  ]
}
EOF
)"

TMP_POLICY="$(mktemp)"
trap 'rm -f "${TMP_POLICY}"' EXIT
echo "${POLICY_DOC}" > "${TMP_POLICY}"

# --- Check for existing policy with same description (our identifier) -------
EXISTING_POLICY_ID="$(aws dlm get-lifecycle-policies \
  --query "Policies[?Description=='${POLICY_DESCRIPTION}'].PolicyId | [0]" \
  --output text)"

if [[ -n "${EXISTING_POLICY_ID}" && "${EXISTING_POLICY_ID}" != "None" ]]; then
  echo "ebs-dlm: updating existing policy ${EXISTING_POLICY_ID} ..."
  aws dlm update-lifecycle-policy \
    --policy-id "${EXISTING_POLICY_ID}" \
    --state ENABLED \
    --policy-details "file://${TMP_POLICY}" \
    --description "${POLICY_DESCRIPTION}" \
    --execution-role-arn "${DLM_ROLE_ARN}" >/dev/null
  echo "    Updated."
else
  echo "ebs-dlm: creating new policy ..."
  NEW_ID="$(aws dlm create-lifecycle-policy \
    --execution-role-arn "${DLM_ROLE_ARN}" \
    --description "${POLICY_DESCRIPTION}" \
    --state ENABLED \
    --policy-details "file://${TMP_POLICY}" \
    --query 'PolicyId' --output text)"
  echo "    Created policy ${NEW_ID}."
fi

# Volume tagging (Name=honeybot-docker-data) is handled automatically by
# scripts/ensure-aws-infra.sh on every secrets-init startup — no manual
# follow-up step here.
