#!/usr/bin/env bash
# Local developer bootstrap (macOS or Linux). Idempotent.
#
# Installs the CLIs a developer needs to work on honeybot OUTSIDE Docker:
#   - 1Password CLI (`op`)
#   - varlock (via npm)
#   - docker + docker compose (check only)
#
# Does NOT install Hermes or the HubSpot CLI \u2014 those live inside the container.

set -euo pipefail

echo "==> checking docker ..."
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed. Install Docker Desktop: https://www.docker.com/products/docker-desktop/" >&2
  exit 1
fi
docker --version
docker compose version || { echo "ERROR: docker compose v2 plugin missing." >&2; exit 1; }

echo "==> checking op (1Password CLI) ..."
if ! command -v op >/dev/null 2>&1; then
  if [[ "$(uname)" == "Darwin" ]]; then
    if command -v brew >/dev/null 2>&1; then
      brew install --cask 1password-cli
    else
      echo "Install Homebrew or install op manually: https://developer.1password.com/docs/cli/get-started" >&2
      exit 1
    fi
  else
    echo "Install op manually: https://developer.1password.com/docs/cli/get-started" >&2
    exit 1
  fi
fi
op --version

echo "==> checking node + npm (for varlock) ..."
if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: Node.js / npm not installed. Install via nvm or brew." >&2
  exit 1
fi

echo "==> installing varlock + 1Password plugin (global) ..."
npm list -g --depth=0 varlock >/dev/null 2>&1 || npm install -g varlock @varlock/1password-plugin
varlock --version

echo ""
echo "==> git hooks: installing pre-commit secret scanner ..."
git -C "$(dirname "$0")/.." config core.hooksPath .githooks

echo ""
echo "All set. Next steps:"
echo "  1. Create ./op.env with: OP_SERVICE_ACCOUNT_TOKEN=ops_... (dev-scoped token)"
echo "  2. docker compose up --build"
