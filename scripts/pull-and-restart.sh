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

# Deploy status file — shared volume so nginx can serve it and the
# honeybot container can read it. Written on every deploy attempt
# (success or failure) so the agent + web UI always have a current
# picture. The path must match the hermes-files mount in docker-compose.
DEPLOY_STATUS_DIR="${DEPLOY_STATUS_DIR:-/srv/hermes-files}"
DEPLOY_STATUS_FILE="${DEPLOY_STATUS_DIR}/deploy-status.json"

# write_deploy_status <status> [extra_fields...]
# Writes a JSON status blob. Status is one of: deploying, success, failed.
write_deploy_status() {
  local status="$1"; shift
  local ts; ts="$(date -u +%FT%TZ)"
  local sha; sha="$(git rev-parse HEAD 2>/dev/null || echo 'unknown')"
  local short; short="${sha:0:7}"
  local branch_name; branch_name="$BRANCH"
  local subject; subject="$(git log -1 --format='%s' 2>/dev/null || echo '')"
  local author; author="$(git log -1 --format='%an' 2>/dev/null || echo '')"

  # Escape double quotes and backslashes for JSON safety (pure bash,
  # no python3 — the redeploy sidecar is Alpine docker:cli).
  subject="${subject//\\/\\\\}"
  subject="${subject//\"/\\\"}"
  author="${author//\\/\\\\}"
  author="${author//\"/\\\"}"

  # Only write if the directory exists (volume is mounted).
  if [[ -d "$DEPLOY_STATUS_DIR" ]]; then
    {
      printf '{\n'
      printf '  "status": "%s",\n' "$status"
      printf '  "sha": "%s",\n' "$sha"
      printf '  "short_sha": "%s",\n' "$short"
      printf '  "branch": "%s",\n' "$branch_name"
      printf '  "commit_subject": "%s",\n' "$subject"
      printf '  "commit_author": "%s",\n' "$author"
      printf '  "timestamp": "%s"' "$ts"
      for kv in "$@"; do
        printf ',\n  %s' "$kv"
      done
      printf '\n}\n'
    } > "$DEPLOY_STATUS_FILE"
  fi
}

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

# Record that a deploy is starting — before the build, so the status
# page shows "deploying" during the (potentially slow) image rebuild.
write_deploy_status "deploying" \
  "\"previous_sha\": \"${before}\"" \
  "\"target_sha\": \"${after}\""

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
  write_deploy_status "failed" \
    "\"stage\": \"build\"" \
    "\"previous_sha\": \"${before}\""
  exit 1
fi

if ! docker compose "${files_args[@]}" up -d; then
  echo "pull-and-restart: docker compose up FAILED for ${after:0:7} on ${BRANCH} (build succeeded, restart did not)" >&2
  write_deploy_status "failed" \
    "\"stage\": \"restart\"" \
    "\"previous_sha\": \"${before}\""
  exit 1
fi

# Deploy succeeded — write the final status.
write_deploy_status "success" \
  "\"previous_sha\": \"${before}\""

echo "pull-and-restart: redeploy complete at ${build_time} (${before:0:7} -> ${after:0:7} on ${BRANCH})"
