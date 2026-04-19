#!/usr/bin/env bash
# EC2 cloud-init user-data for a fresh Amazon Linux 2023 arm64 instance.
# Paste this into the "User data" field when launching a t4g.small.
#
# What it does:
#   - Updates the base OS
#   - Installs Docker + compose plugin + git
#   - Installs 1Password CLI (op) for arm64
#   - Creates /etc/honeybot/ with the right permissions for the op.env secret
#   - Clones the honeybot repo and does a first build (using a deploy key OR
#     falls back to a placeholder state \u2014 see comments below)
#
# After this runs you must SSH in ONCE to write /etc/honeybot/op.env and
# `docker compose up -d`. See bootstrap/README or main README for the runbook.

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
# The ONLY plaintext secret on disk will be OP_SERVICE_ACCOUNT_TOKEN here.
# chmod 600, owned by ec2-user (who runs docker compose).
install -d -m 700 -o ec2-user -g ec2-user /etc/honeybot
echo "==> /etc/honeybot ready. Write op.env manually on first deploy:"
echo "    echo 'OP_SERVICE_ACCOUNT_TOKEN=ops_...' | sudo tee /etc/honeybot/op.env"
echo "    sudo chown ec2-user:ec2-user /etc/honeybot/op.env && sudo chmod 600 /etc/honeybot/op.env"

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
echo "    1. ssh in"
echo "    2. echo 'OP_SERVICE_ACCOUNT_TOKEN=ops_...' | sudo tee /etc/honeybot/op.env"
echo "       sudo chown ec2-user:ec2-user /etc/honeybot/op.env && sudo chmod 600 /etc/honeybot/op.env"
echo "    3. git clone https://github.com/Honeyman-Enterprises/honeybot.git ~/honeybot"
echo "    4. cd ~/honeybot && docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build"
echo "       (starts both 'honeybot' and the 'redeploy' sidecar; the latter"
echo "        auto-rebuilds when origin/main moves)"
echo "==> honeybot user-data finished at $(date -u)"
