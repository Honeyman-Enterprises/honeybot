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
#
# Build-time provenance:
#   Passes --build-arg GIT_SHA / GIT_BRANCH / BUILD_TIME so the resulting
#   image labels itself with what it was built from. The honeybot container
#   reads these via HONEYBOT_GIT_SHA env var; the `version` skill surfaces
#   them on demand.
#
# Failure visibility:
#   No outbound webhook. The deploy story is "watch git for changes",
#   and the operator-facing failure surface is `docker compose logs redeploy`
#   on the host. If a build or restart fails, this script exits non-zero
#   and watch.sh logs the failure to stdout — that's the channel.

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

# Capture build provenance to bake into the image.
build_sha="$(git rev-parse HEAD)"
build_branch="$BRANCH"
build_time="$(date -u +%FT%TZ)"

# Translate colon-separated files into repeated -f args for `docker compose`.
files_args=()
IFS=':' read -r -a _files <<< "$COMPOSE_FILES"
for f in "${_files[@]}"; do
  files_args+=(-f "$f")
done

# Run the rebuild. On failure, log the failing step before bubbling up
# the error. watch.sh will surface it via stdout / `docker compose logs
# redeploy` — there's no webhook fallback, the git-watch + log surface
# is the deploy story.
if ! docker compose "${files_args[@]}" build \
      --build-arg "GIT_SHA=${build_sha}" \
      --build-arg "GIT_BRANCH=${build_branch}" \
      --build-arg "BUILD_TIME=${build_time}"; then
  echo "pull-and-restart: docker compose build FAILED for ${after:0:7} on ${BRANCH}" >&2
  exit 1
fi

if ! docker compose "${files_args[@]}" up -d; then
  echo "pull-and-restart: docker compose up FAILED for ${after:0:7} on ${BRANCH} (build succeeded, restart did not)" >&2
  exit 1
fi

echo "pull-and-restart: redeploy complete at ${build_time} (${before:0:7} -> ${after:0:7} on ${BRANCH})"
