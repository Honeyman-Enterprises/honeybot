#!/usr/bin/env bash
# init-workspace.sh — idempotent setup for the honeybot-dev skill.
#
# - Enforces the dev allow-list.
# - Mints a short-lived GitHub App installation token (via gh-app-token.sh)
#   and exports it as GH_TOKEN for this process.
# - Clones the honeybot repo into ~/workspace/honeybot, or fast-forwards
#   if it already exists.
#
# Fails closed on any missing auth, wrong user, or dirty workspace.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_APP_TOKEN_SCRIPT="${SCRIPT_DIR}/../../_lib/gh-app-token.sh"

WORKSPACE="${HOME}/workspace/honeybot"
REPO_SLUG="${HONEYBOT_REPO_SLUG:?HONEYBOT_REPO_SLUG must be set (e.g. Honeyman-Enterprises/honeybot)}"
BASE_BRANCH="${HONEYBOT_DEV_BASE_BRANCH:-main}"
SLACK_USER="${HONEYBOT_SLACK_USER:?HONEYBOT_SLACK_USER must be set}"

# ----- Allow-list check -----------------------------------------------------
if ! allowed="$(op read "op://Honeybot/GitHub Bot/dev_slack_users" 2>/dev/null)"; then
  echo "init-workspace: cannot read dev allow-list from 1Password." >&2
  echo "               expected op://Honeybot/GitHub Bot/dev_slack_users" >&2
  exit 2
fi
if [[ ",${allowed}," != *",${SLACK_USER},"* ]]; then
  echo "init-workspace: ${SLACK_USER} is not on the honeybot-dev allow-list; refusing." >&2
  exit 3
fi

# ----- Mint GitHub App installation token ----------------------------------
# The App's private key stays in 1Password; this helper signs a JWT, exchanges
# it for a ~60-minute installation token, and writes the token to stdout only.
if [[ ! -x "$GH_APP_TOKEN_SCRIPT" ]]; then
  echo "init-workspace: missing helper ${GH_APP_TOKEN_SCRIPT}" >&2
  exit 2
fi
if ! GH_TOKEN="$("$GH_APP_TOKEN_SCRIPT")"; then
  echo "init-workspace: could not mint GitHub App installation token." >&2
  echo "               see docs/github-app-setup.md for vault layout." >&2
  exit 2
fi
export GH_TOKEN
# gh also respects GITHUB_TOKEN; unset it so our ghs_... token is the one used.
unset GITHUB_TOKEN

# ----- Commit identity ------------------------------------------------------
COMMIT_NAME="${HONEYBOT_COMMIT_NAME:-Honeybot}"
COMMIT_EMAIL="${HONEYBOT_COMMIT_EMAIL:-honeybot@noreply.honeymanenterprises.com}"

# ----- Clone or fast-forward ------------------------------------------------
mkdir -p "$(dirname "$WORKSPACE")"

if [[ ! -d "$WORKSPACE/.git" ]]; then
  echo "init-workspace: cloning ${REPO_SLUG} ..."
  # gh repo clone uses GH_TOKEN for HTTPS auth.
  gh repo clone "$REPO_SLUG" "$WORKSPACE" -- --depth=50
  cd "$WORKSPACE"
  git config user.name  "$COMMIT_NAME"
  git config user.email "$COMMIT_EMAIL"
  # Wire the repo's secret-scan pre-commit hook for this clone. The bot's
  # own commits run through this; --no-verify is never used.
  if [[ -x scripts/install-hooks.sh ]]; then
    ./scripts/install-hooks.sh
  fi
else
  cd "$WORKSPACE"
  # Validate the remote points where we expect.
  actual="$(git config --get remote.origin.url || true)"
  case "$actual" in
    *"${REPO_SLUG}"*) : ;;
    *) echo "init-workspace: remote origin is '${actual}', expected to contain '${REPO_SLUG}'. Refusing." >&2
       exit 4 ;;
  esac
  # Refuse to stomp on uncommitted work.
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "init-workspace: workspace has uncommitted changes. Run abort.sh first." >&2
    exit 5
  fi
  git fetch origin --prune
  git checkout "$BASE_BRANCH"
  git reset --hard "origin/${BASE_BRANCH}"
  git config user.name  "$COMMIT_NAME"
  git config user.email "$COMMIT_EMAIL"
  # Re-wire hooks every init; cheap and survives a git config wipe.
  if [[ -x scripts/install-hooks.sh ]]; then
    ./scripts/install-hooks.sh
  fi
fi

echo "init-workspace: ready at ${WORKSPACE} on ${BASE_BRANCH} @ $(git rev-parse --short HEAD)"
