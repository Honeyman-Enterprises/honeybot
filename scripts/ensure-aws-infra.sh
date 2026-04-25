#!/usr/bin/env sh
# ensure-aws-infra.sh — idempotent AWS-side bring-up, run from secrets-init.
#
# Runs on EVERY `docker compose up` as part of the secrets-init one-shot.
# Does the AWS-side equivalent of seed-vault.sh / emit-runtime-env.sh: makes
# sure the resources we expect on the cloud side actually exist, and bails
# silently on machines that aren't an EC2 instance (laptop dev).
#
# Scope after the EIP + manual route53 setup:
#   1. EBS DLM snapshot policy (account-scoped; once, then verified).
#   2. EBS root volume tag Name=honeybot-docker-data so DLM targets it.
#
# What it does NOT do:
#   - Route53 records. Apex (honeybot.honeymanenterprises.com) is a manual
#     A record pointing at the EIP. If hooks.* / *.honeybot.* CNAMEs are
#     ever needed (Phase 2 webhooks), add them in the console — not here.
#   - TLS certs. lua-resty-acme handles those in-process inside nginx.
#
# Discovery model: we identify the running EC2 instance by tag, NOT by
# IMDSv2. Containers on the docker bridge network can't reliably reach
# 169.254.169.254, but they can hit AWS APIs. Tag-based discovery also
# means this script is a no-op on a laptop with the same AWS creds: if
# no instance is tagged Name=honeybot-prod (or HONEYBOT_INSTANCE_TAG),
# we exit 0 cleanly and let the rest of secrets-init proceed.
#
# AWS creds are read from 1Password via the same op CLI / service account
# token used by seed-vault.sh and emit-runtime-env.sh.

set -eu

INSTANCE_TAG="${HONEYBOT_INSTANCE_TAG:-honeybot-prod}"
DATA_VOLUME_TAG="honeybot-docker-data"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DLM_SCRIPT="${SCRIPT_DIR}/aws-infra/ebs-dlm-snapshot-policy.sh"

log() { printf 'ensure-aws-infra: %s\n' "$*"; }
die() { printf 'ensure-aws-infra: FATAL: %s\n' "$*" >&2; exit 1; }

[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || die "OP_SERVICE_ACCOUNT_TOKEN not set"
command -v op  >/dev/null 2>&1 || die "op CLI missing"
command -v aws >/dev/null 2>&1 || die "aws CLI missing"

# --- Pull AWS creds from 1Password ------------------------------------------
# Same vault layout as seed-vault.sh: op://Honeybot/AWS/{access_key_id,
# secret_access_key,default_region}. Empty values are a fail-closed signal
# that the human hasn't filled the vault item yet.
read_or_empty() {
  op read "$1" 2>/dev/null || true
}

AWS_ACCESS_KEY_ID="$(read_or_empty 'op://Honeybot/AWS/access_key_id')"
AWS_SECRET_ACCESS_KEY="$(read_or_empty 'op://Honeybot/AWS/secret_access_key')"
AWS_DEFAULT_REGION="$(read_or_empty 'op://Honeybot/AWS/default_region')"

if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
  log "AWS creds not populated in 1Password — skipping AWS infra ensure."
  log "  (Fill op://Honeybot/AWS/{access_key_id,secret_access_key} to enable.)"
  exit 0
fi

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# --- Locate the running EC2 instance by tag ---------------------------------
# If nothing matches, we assume this is a laptop / non-prod environment and
# exit cleanly. The DLM policy is account-wide, so we still ensure it below
# only when a real instance is found — a laptop run shouldn't be creating
# IAM roles in the account.
log "looking for EC2 instance tagged Name=${INSTANCE_TAG} ..."
INSTANCE_INFO="$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${INSTANCE_TAG}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[0].[InstanceId,PublicIpAddress]' \
  --output text 2>/dev/null || true)"

if [ -z "${INSTANCE_INFO}" ] || [ "${INSTANCE_INFO}" = "None" ]; then
  log "no running instance tagged Name=${INSTANCE_TAG} — skipping (laptop dev?)."
  exit 0
fi

INSTANCE_ID="$(printf '%s' "${INSTANCE_INFO}" | awk '{print $1}')"
PUBLIC_IP="$(printf '%s' "${INSTANCE_INFO}" | awk '{print $2}')"
log "found instance ${INSTANCE_ID} (public IP ${PUBLIC_IP})"

# --- Ensure DLM snapshot policy ---------------------------------------------
# The existing aws-infra/ebs-dlm-snapshot-policy.sh script is idempotent:
# it creates the DLM IAM role if missing, then upserts the policy by
# description. Safe to call on every boot.
[ -x "${DLM_SCRIPT}" ] || die "missing or non-executable: ${DLM_SCRIPT}"
log "ensuring EBS DLM snapshot policy ..."
bash "${DLM_SCRIPT}"

# --- Tag the root EBS volume so DLM actually targets it ---------------------
# t4g.small launches with a single 20GB gp3 root volume on /dev/xvda. That
# IS the data volume — there's no separate /data EBS in this topology. We
# only need to tag it once (Name=honeybot-docker-data); DLM then picks it
# up on its next schedule firing.
log "looking up root EBS volume for ${INSTANCE_ID} ..."
VOLUME_ID="$(aws ec2 describe-volumes \
  --filters "Name=attachment.instance-id,Values=${INSTANCE_ID}" \
  --query 'Volumes[?Attachments[?Device==`/dev/xvda` || Device==`/dev/sda1`]].VolumeId | [0]' \
  --output text 2>/dev/null || true)"

if [ -z "${VOLUME_ID}" ] || [ "${VOLUME_ID}" = "None" ]; then
  die "could not find root EBS volume on ${INSTANCE_ID} (expected /dev/xvda or /dev/sda1)"
fi
log "root volume: ${VOLUME_ID}"

# Check existing Name tag. create-tags is itself idempotent, but we log
# whether this was a no-op so the secrets-init log is informative.
EXISTING_NAME="$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=${VOLUME_ID}" "Name=key,Values=Name" \
  --query 'Tags[0].Value' --output text 2>/dev/null || true)"

if [ "${EXISTING_NAME}" = "${DATA_VOLUME_TAG}" ]; then
  log "volume ${VOLUME_ID} already tagged Name=${DATA_VOLUME_TAG} — no-op."
else
  if [ -n "${EXISTING_NAME}" ] && [ "${EXISTING_NAME}" != "None" ]; then
    log "overwriting existing Name=${EXISTING_NAME} on ${VOLUME_ID}"
  fi
  aws ec2 create-tags \
    --resources "${VOLUME_ID}" \
    --tags "Key=Name,Value=${DATA_VOLUME_TAG}" >/dev/null
  log "tagged ${VOLUME_ID} Name=${DATA_VOLUME_TAG}"
fi

log "done."
