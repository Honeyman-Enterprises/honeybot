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
# Slack notifications:
#   On a successful rebuild, posts a one-line summary to the channel ID
#   in $HONEYBOT_REDEPLOY_NOTIFY_CHANNEL using the bot token from
#   op://Honeybot/Slack Bot/bot_token. On failure, same channel gets a
#   loud message with the failing step. Notifications are best-effort —
#   if op is unreachable or the channel ID is unset, the redeploy still
#   runs and the failure is just logged.

set -euo pipefail

REPO_DIR="${HONEYBOT_REPO_DIR:-$HOME/honeybot}"
BRANCH="${HONEYBOT_DEV_BASE_BRANCH:-main}"

# Which compose overlays to use. Override HONEYBOT_COMPOSE_FILES if you want
# a different layout (e.g. docker-compose.yml only for local testing).
COMPOSE_FILES="${HONEYBOT_COMPOSE_FILES:-docker-compose.yml:docker-compose.prod.yml}"

cd "$REPO_DIR"

# ----- Slack notification helper -------------------------------------------
# Best-effort: returns 0 on any local failure so the main flow never aborts
# on a notification problem. Posts to a Slack incoming webhook URL provided
# via $HONEYBOT_REDEPLOY_NOTIFY_WEBHOOK.
#
# Where the value comes from:
#   1Password → `op://Honeybot/Slack Bot/redeploy_webhook_url`
#     ↓ (read by `secrets-init` service at compose-up time)
#   `/repo/.env.runtime` (chmod 600, gitignored, dockerignored)
#     ↓ (loaded as env_file in the redeploy service)
#   $HONEYBOT_REDEPLOY_NOTIFY_WEBHOOK in this script's env
#
# This keeps the redeploy sidecar — which has no `op` CLI and no service-
# account token — from ever seeing the secret in a compose interpolation
# or host shell. `secrets-init` is the single op-aware boundary in the
# stack; everything else consumes materialized files.
#
# The redeploy sidecar's image is alpine + docker + git + curl + bash —
# no python, no jq — so this helper builds the JSON payload itself with a
# tiny shell escape.
notify_slack() {
  local message="$1"
  local webhook="${HONEYBOT_REDEPLOY_NOTIFY_WEBHOOK:-}"
  [[ -z "$webhook" ]] && return 0

  # Minimal JSON-string escaping. Slack's webhook accepts {"text": "..."}
  # so we just need to escape backslash, double-quote, and control chars.
  # awk is in alpine's busybox by default.
  local escaped
  escaped="$(printf '%s' "$message" | awk '
    BEGIN { ORS=""; }
    {
      if (NR > 1) printf "\\n"
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if      (c == "\\") printf "\\\\"
        else if (c == "\"") printf "\\\""
        else                printf "%s", c
      }
    }
  ')"

  curl -sS -X POST -H 'Content-Type: application/json; charset=utf-8' \
    --data "{\"text\": \"${escaped}\"}" \
    "$webhook" >/dev/null 2>&1 || true
  return 0
}

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

# Run the rebuild. On failure, notify Slack with the failing step before
# bubbling up the error.
if ! docker compose "${files_args[@]}" build \
      --build-arg "GIT_SHA=${build_sha}" \
      --build-arg "GIT_BRANCH=${build_branch}" \
      --build-arg "BUILD_TIME=${build_time}"; then
  notify_slack ":x: *honeybot redeploy failed* during \`docker compose build\` for ${after:0:7} on ${BRANCH}. See \`docker compose logs redeploy\` on the host."
  exit 1
fi

if ! docker compose "${files_args[@]}" up -d; then
  notify_slack ":x: *honeybot redeploy failed* during \`docker compose up\` for ${after:0:7} on ${BRANCH}. Build succeeded but container restart did not."
  exit 1
fi

echo "pull-and-restart: redeploy complete at ${build_time}"
notify_slack ":white_check_mark: *honeybot redeployed* \`${before:0:7}\` → \`${after:0:7}\` on ${BRANCH} at ${build_time}"
