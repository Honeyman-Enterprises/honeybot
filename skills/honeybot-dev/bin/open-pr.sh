#!/usr/bin/env bash
# open-pr.sh — stage + commit all workspace changes, push the claude/* branch,
# and open a pull request against $HONEYBOT_DEV_BASE_BRANCH.
#
# Refuses on main/master. Refuses if branch doesn't start with claude/.
# Refuses if there are no changes to commit. Never merges. Never force-pushes.
#
# Usage: open-pr.sh "<title>" "<body>"

set -euo pipefail

WORKSPACE="${HOME}/workspace/honeybot"
BASE_BRANCH="${HONEYBOT_DEV_BASE_BRANCH:-main}"

title="${1:-}"
body="${2:-}"

if [[ -z "$title" ]]; then
  echo "usage: open-pr.sh \"<title>\" \"<body>\"" >&2
  exit 2
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "open-pr: GH_TOKEN not set. Run init-workspace.sh first." >&2
  exit 2
fi

cd "$WORKSPACE"

branch="$(git rev-parse --abbrev-ref HEAD)"

# Hard refuse on base branches.
case "$branch" in
  main|master|"$BASE_BRANCH")
    echo "open-pr: refusing to open PR from base branch '${branch}'. Run start-branch.sh first." >&2
    exit 3
    ;;
esac

# Only operate on claude/* branches — the only namespace this skill owns.
if [[ "$branch" != claude/* ]]; then
  echo "open-pr: branch '${branch}' is not under claude/*. Refusing." >&2
  echo "         Only branches created by start-branch.sh are eligible." >&2
  exit 3
fi

# Something must actually have changed.
if git diff --quiet && git diff --cached --quiet && [[ -z "$(git status --porcelain)" ]]; then
  echo "open-pr: no changes in workspace. Nothing to commit." >&2
  exit 4
fi

# Stage everything under the workspace. Named files only — never -A on the
# whole tree if it would sweep in stray dotfiles; here the whole workspace
# IS the tree and .gitignore is the guard.
git add -A

# Commit. Pre-commit hooks (secret scan) run here — if they fail we stop.
# We intentionally DO NOT pass --no-verify: a failing hook means the bot
# tried to commit a secret, and we want that surfaced loudly.
if ! git commit -m "$title" ${body:+-m "$body"}; then
  echo "open-pr: commit failed (likely pre-commit hook rejected it). Stopping." >&2
  echo "         Fix the underlying issue (probably a leaked secret) and retry." >&2
  exit 5
fi

# Push the branch. -u sets upstream so subsequent pushes on the same branch
# work without repeating the remote. --no-force is the default; we never
# pass --force anywhere in this skill.
git push -u origin "$branch"

# Open the PR. gh auth is done via GH_TOKEN from the env (set by init-workspace).
pr_url="$(gh pr create \
  --base "$BASE_BRANCH" \
  --head "$branch" \
  --title "$title" \
  --body  "${body:-_(no description provided)_}" \
  2>&1)"

rc=$?
if [[ $rc -ne 0 ]]; then
  echo "open-pr: gh pr create failed:" >&2
  echo "$pr_url" >&2
  exit 6
fi

# gh prints the PR URL to stdout on success. Echo it cleanly for the caller.
echo "$pr_url"
