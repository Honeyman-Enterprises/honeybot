#!/usr/bin/env bash
# Deploy honeybot to the EC2 instance.
#
# Assumes:
#   - You can SSH as ec2-user@$HONEYBOT_HOST using your configured key.
#   - The instance has already run bootstrap/ec2-userdata.sh (docker, op, dirs).
#   - /etc/honeybot/op.env exists on the instance with OP_SERVICE_ACCOUNT_TOKEN.
#
# Usage:
#   HONEYBOT_HOST=ec2-xx-xx-xx-xx.compute.amazonaws.com ./scripts/deploy.sh
#
# What it does:
#   1. Builds the image locally for linux/arm64 using buildx.
#   2. Saves the image to a tarball, scp's it to the EC2 box, loads it.
#      (Avoids needing a registry; simple for single-instance v1.)
#   3. rsyncs compose + config files.
#   4. `docker compose up -d` on the remote.

set -euo pipefail

: "${HONEYBOT_HOST:?Set HONEYBOT_HOST to your EC2 public DNS or IP}"
SSH_USER="${HONEYBOT_SSH_USER:-ec2-user}"
REMOTE_DIR="${HONEYBOT_REMOTE_DIR:-/home/${SSH_USER}/honeybot}"
IMAGE_TAG="honeybot/hermes:prod"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> building ${IMAGE_TAG} for linux/arm64 ..."
docker buildx build \
  --platform linux/arm64 \
  --load \
  -t "${IMAGE_TAG}" \
  .

echo "==> saving image to tarball ..."
TAR=/tmp/honeybot-hermes-prod.tar
docker save "${IMAGE_TAG}" -o "$TAR"

echo "==> preparing remote dir on ${HONEYBOT_HOST} ..."
ssh "${SSH_USER}@${HONEYBOT_HOST}" "mkdir -p '${REMOTE_DIR}'"

echo "==> rsync compose + config ..."
rsync -av --delete \
  --exclude '.git' \
  --exclude '.hermes' \
  --exclude 'op.env' \
  --exclude 'node_modules' \
  --exclude '__pycache__' \
  docker-compose.yml docker-compose.prod.yml \
  hermes-config skills .env.schema \
  "${SSH_USER}@${HONEYBOT_HOST}:${REMOTE_DIR}/"

echo "==> shipping image ..."
scp "$TAR" "${SSH_USER}@${HONEYBOT_HOST}:/tmp/honeybot-hermes-prod.tar"

echo "==> loading image + restarting ..."
ssh "${SSH_USER}@${HONEYBOT_HOST}" bash -lc "'
  set -euo pipefail
  docker load -i /tmp/honeybot-hermes-prod.tar
  rm /tmp/honeybot-hermes-prod.tar
  cd \"${REMOTE_DIR}\"
  # On prod, op.env lives at /etc/honeybot/op.env \u2014 symlink so compose finds it.
  [ -L op.env ] || ln -sf /etc/honeybot/op.env op.env
  docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
  docker compose logs --tail=50
'"

rm -f "$TAR"
echo ""
echo "==> deploy complete. Tail logs with:"
echo "    ssh ${SSH_USER}@${HONEYBOT_HOST} 'cd ${REMOTE_DIR} && docker compose logs -f'"
