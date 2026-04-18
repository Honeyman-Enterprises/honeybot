#!/usr/bin/env bash
# install-hooks.sh — wire the repo's .githooks directory into git.
#
# Run once per fresh clone (including the workspace clone that the
# honeybot-dev skill uses — init-workspace.sh can source this).
#
# git config core.hooksPath is per-repo config; it does not travel with a
# clone, which is why we ship this script instead of assuming it's set.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  echo "install-hooks: not inside a git repo." >&2
  exit 1
fi

cd "$repo_root"

if [[ ! -d .githooks ]]; then
  echo "install-hooks: .githooks directory missing at ${repo_root}." >&2
  exit 2
fi

git config core.hooksPath .githooks

# Make sure every hook is executable. chmod is idempotent.
find .githooks -maxdepth 1 -type f -exec chmod +x {} +

echo "install-hooks: core.hooksPath set to .githooks (hooks in $(ls .githooks | tr '\n' ' '))"
