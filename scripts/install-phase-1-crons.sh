#!/usr/bin/env bash
# Install host-level crons added during Phase 1.
#
# Current crons:
#   * daily Route53 re-upsert at 04:30 UTC. EC2 without an Elastic IP
#     can get a new public IP on stop/start; this keeps DNS in sync.
#
# Idempotent: overwrites the honeybot user's crontab with the canonical
# set, so removed entries in this file disappear on next run.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Run as whichever user invokes this; the crontab is per-user.
CRON_TMP="$(mktemp)"
trap 'rm -f "${CRON_TMP}"' EXIT

cat > "${CRON_TMP}" <<EOF
# -------- managed by honeybot scripts/install-phase-1-crons.sh --------
# Daily Route53 re-upsert — keeps DNS pointed at this EC2's public IP
# even if the IP changes after a stop/start (we don't pay for EIP).
# Uses varlock so AWS creds come from 1Password, not the shell env.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
30 4 * * * cd ${REPO_DIR} && varlock run -- ./aws-infra/route53-upsert.sh >> /var/log/honeybot-route53-upsert.log 2>&1
# ----------------------------------------------------------------------
EOF

crontab "${CRON_TMP}"
echo "install-phase-1-crons: crontab installed for $(whoami)"
crontab -l
