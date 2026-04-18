#!/usr/bin/env bash
# abort.sh — bail out of an in-progress self-edit.
#
# - Resets the working tree to HEAD (discards uncommitted changes).
# - Checks out the base branch.
# - Deletes the local claude/<slug> branch.
# - Does NOT touch the remote. If a PR was already opened, the human
#   reviewer decides what to do with it.
#
# Safe to run even when the workspace is already clean.

set -euo pipefail

WORKSPACE="${HOME}/workspace/honeybot"
BASE_BRANCH="${HONEYBOT_DEV_BASE_BRANCH:-main}"

cd "$WORKSPACE"

cur="$(git rev-parse --abbrev-ref HEAD)"

# Discard any uncommitted work, including untracked files inside the repo.
# This is destructive on purpose — abort is the "get me back to a known
# state" button. It must never touch things OUTSIDE $WORKSPACE.
git reset --hard HEAD
git clean -fd

# If we're already on the base branch there's no per-branch cleanup to do.
if [[ "$cur" == "$BASE_BRANCH" ]]; then
  echo "abort: already on ${BASE_BRANCH}, workspace reset to HEAD."
  exit 0
fi

# We only manage claude/* branches. Refuse to delete anything else — a human
# must have checked out a non-claude branch manually and we shouldn't nuke it.
if [[ "$cur" != claude/* ]]; then
  echo "abort: current branch '${cur}' is not under claude/*; will not delete it." >&2
  echo "       Switching to ${BASE_BRANCH} and leaving '${cur}' intact." >&2
  git checkout "$BASE_BRANCH"
  exit 0
fi

git checkout "$BASE_BRANCH"

# -D (force delete) because the branch might have unmerged commits that
# were pushed to a PR but never merged. The remote branch is untouched.
git branch -D "$cur"

echo "abort: reset to ${BASE_BRANCH}; local branch '${cur}' deleted (remote untouched)."
