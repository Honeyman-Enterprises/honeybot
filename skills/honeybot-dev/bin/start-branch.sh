#!/usr/bin/env bash
# start-branch.sh — create a fresh claude/<slug> branch from clean base.
#
# Assumes init-workspace.sh already ran in this shell.

set -euo pipefail

WORKSPACE="${HOME}/workspace/honeybot"
BASE_BRANCH="${HONEYBOT_DEV_BASE_BRANCH:-main}"

slug="${1:-}"
if [[ -z "$slug" ]]; then
  echo "usage: start-branch.sh <slug>" >&2
  exit 2
fi

# Strict slug shape.
if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,50}$ ]]; then
  echo "start-branch: slug '${slug}' must match ^[a-z0-9][a-z0-9-]{1,50}\$ (no spaces, no slashes)." >&2
  exit 2
fi

case "$slug" in
  main|master|develop|release*|hotfix*) \
    echo "start-branch: slug '${slug}' is reserved. Pick something more specific." >&2
    exit 2 ;;
esac

branch="claude/${slug}"

cd "$WORKSPACE"

# Make sure we're starting from clean base.
cur="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$cur" != "$BASE_BRANCH" ]]; then
  echo "start-branch: expected to be on ${BASE_BRANCH}, but on ${cur}. Run init-workspace.sh first." >&2
  exit 4
fi

# Refuse if this branch already exists anywhere (local or remote).
if git show-ref --verify --quiet "refs/heads/${branch}"; then
  echo "start-branch: local branch '${branch}' already exists. Pick a different slug." >&2
  exit 5
fi
if git ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1; then
  echo "start-branch: remote branch '${branch}' already exists. Pick a different slug." >&2
  exit 5
fi

git checkout -b "$branch"
echo "start-branch: on ${branch} (from ${BASE_BRANCH} @ $(git rev-parse --short HEAD~0))"
