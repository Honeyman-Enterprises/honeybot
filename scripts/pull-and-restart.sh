#!/usr/bin/env bash
# pull-and-restart.sh — fetch main, rebuild, restart.
#
# Primary invoker: the `redeploy` sidecar container (see redeploy/watch.sh
# and the `redeploy` service in docker-compose.yml). That sidecar bind-
# mounts the host repo + docker socket and runs this script on a loop.
#
# Also usable manually (on the host, after merging a PR):
#   ./scripts/pull-and-restart.sh
#
# Fallback cron usage (if the sidecar is disabled for some reason):
#   */10 * * * * cd /home/ec2-user/honeybot && ./scripts/pull-and-restart.sh >> /var/log/honeybot-redeploy.log 2>&1
#
# Idempotent. If origin/main hasn't moved since last run, it does nothing
# (no rebuild, no restart, no log spam).

set -euo pipefail

REPO_DIR="${HONEYBOT_REPO_DIR:-$HOME/honeybot}"
BRANCH="${HONEYBOT_DEV_BASE_BRANCH:-main}"

# Which compose overlays to use. Override HONEYBOT_COMPOSE_FILES if you want
# a different layout (e.g. docker-compose.yml only for local testing).
COMPOSE_FILES="${HONEYBOT_COMPOSE_FILES:-docker-compose.yml:docker-compose.prod.yml}"

cd "$REPO_DIR"

# Refuse to touch a dirty working tree — never stomp on someone's in-flight
# debug edits on the EC2 host.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "pull-and-restart: ${REPO_DIR} has uncommitted changes; refusing." >&2
  exit 1
fi

before="$(git rev-parse HEAD)"
git fetch origin --prune
after="$(git rev-parse "origin/${BRANCH}")"

if [[ "$before" == "$after" ]]; then
  # No change; exit quietly so cron logs stay readable.
  exit 0
fi

echo "pull-and-restart: ${before:0:7} -> ${after:0:7} on ${BRANCH}"
git reset --hard "origin/${BRANCH}"

# Translate colon-separated files into repeated -f args for `docker compose`.
files_args=()
IFS=':' read -r -a _files <<< "$COMPOSE_FILES"
for f in "${_files[@]}"; do
  files_args+=(-f "$f")
done

docker compose "${files_args[@]}" up -d --build

echo "pull-and-restart: redeploy complete at $(date -u +%FT%TZ)"
