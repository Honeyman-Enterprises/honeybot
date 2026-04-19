#!/usr/bin/env bash
# watch.sh — in-container poller that redeploys honeybot when origin/main moves.
#
# Runs as PID 1 in the `redeploy` sidecar. Loops:
#   1. sleep $HONEYBOT_POLL_INTERVAL
#   2. invoke /repo/scripts/pull-and-restart.sh
#      (which no-ops if origin hasn't moved; rebuilds + restarts if it has)
#
# Why a sidecar and not host cron:
#   - Deploys + redeploys with the compose project. One artifact to ship.
#   - Logs go to `docker compose logs redeploy` next to honeybot logs.
#   - No host-side systemd/cron to provision.
#
# Why no auth:
#   - The honeybot repo is public. Anonymous HTTPS `git fetch` works.
#   - If it ever goes private, source skills/_lib/gh-app-token.sh here and
#     configure `git -c http.extraHeader="Authorization: Bearer $TOKEN" fetch`.

set -euo pipefail

INTERVAL="${HONEYBOT_POLL_INTERVAL:-120}"
REPO_DIR="${HONEYBOT_REPO_DIR:-/repo}"
export HONEYBOT_REPO_DIR="$REPO_DIR"

# Safety: if the mount is wrong, fail loud and exit. `restart: unless-stopped`
# will not loop us back since we exit non-zero on a config error.
if [[ ! -d "${REPO_DIR}/.git" ]]; then
  echo "watch: ${REPO_DIR} is not a git repo (is the bind-mount wired?)" >&2
  exit 1
fi
if [[ ! -x "${REPO_DIR}/scripts/pull-and-restart.sh" ]]; then
  echo "watch: ${REPO_DIR}/scripts/pull-and-restart.sh not executable" >&2
  exit 1
fi

# Treat the bind-mounted host repo as a safe directory for git operations.
# Without this, git refuses to run when the on-disk ownership doesn't match
# the container's uid (common with bind mounts from ec2-user → container root).
git config --global --add safe.directory "$REPO_DIR"

echo "watch: polling ${REPO_DIR} every ${INTERVAL}s (branch=${HONEYBOT_DEV_BASE_BRANCH:-main})"

# One immediate tick so a fresh deploy doesn't sit idle for INTERVAL seconds
# before picking up anything committed during the redeploy race.
while true; do
  if ! "${REPO_DIR}/scripts/pull-and-restart.sh"; then
    # Don't die on a single failed cycle — network hiccup, transient git
    # error, etc. Log it and retry next tick.
    echo "watch: pull-and-restart exited non-zero (retry in ${INTERVAL}s)" >&2
  fi
  sleep "$INTERVAL"
done
