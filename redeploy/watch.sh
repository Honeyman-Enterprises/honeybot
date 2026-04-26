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

# ---- docker.sock GID pre-flight ------------------------------------------
# The sidecar runs as a non-root UID with `group_add: ${HONEYBOT_DOCKER_GID}`
# in docker-compose.yml. If the operator never set HONEYBOT_DOCKER_GID on
# the host (or set it wrong), `group_add` falls back to the AL2023 default
# (988), which on most other distros (Ubuntu=999, Debian varies, etc.)
# does NOT match the actual GID of /var/run/docker.sock. The result is a
# silent infinite loop of "permission denied" on every poll, with no
# operator-visible signal beyond the logs nobody tails.
#
# Catch this at startup, fail loud, and tell the operator the exact env
# var to set + the value to set it to. The docker-compose `restart` policy
# (`always` in prod, `unless-stopped` in dev) will keep restarting us with
# the same error — that's fine: the loud message keeps showing up on every
# `docker compose logs redeploy` until somebody reads it.
SOCK_PATH="/var/run/docker.sock"
if [[ -S "$SOCK_PATH" ]]; then
  sock_gid="$(stat -c '%g' "$SOCK_PATH")"
  if ! id -G | tr ' ' '\n' | grep -qx "$sock_gid"; then
    cat >&2 <<EOF
watch: pre-flight FAILED — cannot access docker.sock.

  /var/run/docker.sock GID:   $sock_gid
  this container's groups:    $(id -G)
  this container's user:      $(id -u):$(id -g)

The redeploy sidecar runs as a non-root UID and relies on \`group_add\` in
docker-compose.yml to attach the host's docker group. The default value
(988) matches Amazon Linux 2023; your host appears to use a different GID.

Without this, every poll cycle will fail with "permission denied while
trying to connect to the Docker daemon socket" — the sidecar fetches and
resets origin/main fine, then dies trying to issue \`docker compose build\`.

Fix on the host:

  export HONEYBOT_DOCKER_GID=\$(stat -c '%g' /var/run/docker.sock)
  cd ~/honeybot
  docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d \\
    --force-recreate --no-deps redeploy

(persist the export in your shell rc / start script so it survives reboots)

Exiting now so this message is the most recent thing in the logs.
EOF
    exit 2
  fi
else
  echo "watch: pre-flight FAILED — $SOCK_PATH is not a socket. Bind mount missing?" >&2
  exit 2
fi

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
