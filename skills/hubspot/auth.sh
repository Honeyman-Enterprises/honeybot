#!/usr/bin/env bash
# Authenticate the HubSpot CLI using a Personal Access Key already stored in
# 1Password (vault: Honeybot, item: HubSpot, field: personal_access_key).
#
# Requires HUBSPOT_PERSONAL_ACCESS_KEY in the environment \u2014 Varlock resolves
# this from 1Password at container start.
#
# NEVER echo $HUBSPOT_PERSONAL_ACCESS_KEY. Redirect stderr of failing commands
# carefully so the key is not printed in logs.

set -euo pipefail

if [[ -z "${HUBSPOT_PERSONAL_ACCESS_KEY:-}" ]]; then
  echo "ERROR: HUBSPOT_PERSONAL_ACCESS_KEY is not set." >&2
  echo "Michelle must provide a Personal Access Key via Slack DM first;" >&2
  echo "the hubspot skill stores it in 1Password and re-runs this script." >&2
  exit 2
fi

if ! command -v hs >/dev/null 2>&1; then
  echo "ERROR: hs CLI not installed. Run ./install.sh first." >&2
  exit 3
fi

# Configure hs non-interactively. Uses the CLI's personal-access-key flow.
# Docs: https://developers.hubspot.com/docs/local-development-cli/authentication
#
# We intentionally pipe the key on stdin rather than passing via argv so it
# doesn't land in `ps` output or shell history.

tmp_cfg="$(mktemp)"
trap 'rm -f "$tmp_cfg"' EXIT

# `hs init` / `hs auth` variants differ across CLI versions. Use the
# modern `hs auth` subcommand with --auth-type and feed key via env.
HS_AUTH_TYPE=personalaccesskey
HS_ACCOUNT_NAME="${HS_ACCOUNT_NAME:-honeyman-default}"

# `hs auth personalaccesskey` reads the key from stdin in recent versions.
printf '%s\n' "$HUBSPOT_PERSONAL_ACCESS_KEY" | \
  hs auth personalaccesskey \
    --name "$HS_ACCOUNT_NAME" \
    --config "$tmp_cfg" \
  2> >(grep -v -E 'pat-[a-z0-9-]+' >&2 || true)

# Move the generated config into the CLI's default location if needed. The
# CLI writes to ~/.hs-config.yml by default; when using --config we have to
# place it explicitly.
install -m 600 "$tmp_cfg" "${HOME}/.hs-config.yml"

echo "HubSpot authenticated as: ${HS_ACCOUNT_NAME}"
hs accounts list
