#!/usr/bin/env bash
# EC2 cloud-init user-data for a fresh Amazon Linux 2023 arm64 instance.
# Paste this into the "User data" field when launching a t4g.small.
#
# What it does:
#   - Updates the base OS
#   - Installs Docker + compose plugin + git
#   - Installs 1Password CLI (op) for arm64
#   - Clones the honeybot repo and does a first build (using a deploy key OR
#     falls back to a placeholder state \u2014 see comments below)
#
# After this runs you must SSH in ONCE to write ./op.env in the repo dir
# (see "Next steps" at the bottom) and `docker compose up -d`.
# See bootstrap/README or main README for the runbook.

set -euo pipefail
exec > >(tee -a /var/log/honeybot-userdata.log) 2>&1
echo "==> honeybot user-data starting at $(date -u)"

# ---- OS + Docker ----------------------------------------------------------
dnf update -y
# NOTE on curl: AL2023 ships `curl-minimal` in the base AMI. We do NOT list
# `curl` explicitly — the minimal build handles every curl invocation in this
# script. BUT transitive deps (e.g. a package that `Requires: curl` rather
# than `curl-minimal`) can still trigger the `curl-minimal` vs `curl` file
# conflict on /usr/bin/curl, which aborts the whole dnf transaction under
# `set -e`. `--allowerasing` lets dnf swap curl-minimal → curl if a dep
# demands it. Net cost: ~1 MB and slightly more attack surface. Worth it
# for a bootstrap that must not fail.
dnf install -y --allowerasing docker git unzip tar jq
systemctl enable --now docker
usermod -aG docker ec2-user

# Docker compose plugin (Amazon Linux 2023 ships docker but not compose v2).
DOCKER_CFG=/usr/libexec/docker/cli-plugins
install -d -m 755 "$DOCKER_CFG"
COMPOSE_VER=v2.29.7
curl -sSfL "https://github.com/docker/compose/releases/download/${COMPOSE_VER}/docker-compose-linux-aarch64" \
  -o "${DOCKER_CFG}/docker-compose"
chmod +x "${DOCKER_CFG}/docker-compose"
docker compose version

# ---- 1Password CLI (op) ---------------------------------------------------
OP_VERSION=2.30.3
curl -sSfL "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_arm64_v${OP_VERSION}.zip" \
  -o /tmp/op.zip
unzip -o /tmp/op.zip -d /usr/local/bin
rm /tmp/op.zip
op --version

# ---- Secret location ------------------------------------------------------
# The ONLY plaintext secret on disk will be OP_SERVICE_ACCOUNT_TOKEN, at
# ./op.env in the cloned repo dir (same path as local dev). Gitignored and
# excluded from the image build. ec2-user owns the clone, so no sudo needed.
echo "==> Secret file location: /home/ec2-user/honeybot/op.env (created by hand on first deploy — see Next steps)"

# ---- Clone repo (optional) ------------------------------------------------
# If you want user-data to clone on first boot, configure a read-only deploy
# key in GitHub and put its private key at /home/ec2-user/.ssh/honeybot_deploy
# before booting (via SSM Parameter Store or manual copy). Otherwise, SSH in
# and clone by hand \u2014 simpler for v1.
#
# Example (commented):
# sudo -u ec2-user -H bash -lc '
#   mkdir -p ~/.ssh && chmod 700 ~/.ssh
#   git clone git@github.com:honeyman/honeybot.git ~/honeybot
# '

# ---- Redeploy model -------------------------------------------------------
# The honeybot repo is public. We build straight from the Dockerfile on each
# deploy — no registry. Auto-redeploy is handled by the `redeploy` sidecar
# in docker-compose.yml, which polls origin/main and re-runs
# `scripts/pull-and-restart.sh` when a new commit lands. Nothing to wire
# into host cron on the happy path.
echo "==> Next steps:"
echo "    1. ssh / SSM in as ec2-user"
echo "    2. git clone https://github.com/Honeyman-Enterprises/honeybot.git ~/honeybot"
echo "    3. cd ~/honeybot"
echo "       echo 'OP_SERVICE_ACCOUNT_TOKEN=ops_...' > op.env && chmod 600 op.env"
echo "    4. docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build"
echo "       (starts both 'honeybot' and the 'redeploy' sidecar; the latter"
echo "        auto-rebuilds when origin/main moves)"
echo "==> honeybot user-data finished at $(date -u)"
