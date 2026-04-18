#!/usr/bin/env bash
# Install the HubSpot CLI (@hubspot/cli) into the running container.
# Safe to run repeatedly: npm install -g is idempotent.
#
# Called by the `hubspot` skill when `hs --version` fails.

set -euo pipefail

HS_MIN_VERSION="8.4.0"

if command -v hs >/dev/null 2>&1; then
  current="$(hs --version 2>/dev/null | head -n1 || true)"
  echo "hubspot CLI already installed: ${current}"
  exit 0
fi

echo "installing @hubspot/cli (>=${HS_MIN_VERSION}) ..."
npm install -g --omit=dev "@hubspot/cli@latest"

installed="$(hs --version 2>/dev/null | head -n1)"
echo "installed: ${installed}"
