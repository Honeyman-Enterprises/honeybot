#!/usr/bin/env bash
# One-time 1Password bootstrap for the "Honeybot" vault.
#
# Run this ONCE, locally, signed in as your human 1Password user (NOT the
# service account). It creates the vault and the three seed items with the
# correct field names that .env.schema references.
#
# After this runs:
#   1. Go to 1Password web > Developer > Directory > Infrastructure Secrets
#      Management > Create a Service Account named "honeybot-hermes-ec2".
#   2. Grant it read_items + write_items on the "Honeybot" vault only.
#   3. Copy the ops_... token. Save it to your personal vault as "Honeybot
#      Service Account Token", and also write it to ./op.env for local dev:
#        echo "OP_SERVICE_ACCOUNT_TOKEN=ops_..." > ./op.env && chmod 600 ./op.env

set -euo pipefail

VAULT="${HONEYBOT_VAULT:-Honeybot}"

if ! command -v op >/dev/null 2>&1; then
  echo "ERROR: op CLI not installed. See bootstrap/install-deps.sh." >&2
  exit 1
fi

if ! op whoami >/dev/null 2>&1; then
  echo "Sign in to 1Password CLI first: \`eval \$(op signin)\`" >&2
  exit 1
fi

echo "==> ensuring vault '${VAULT}' exists ..."
if ! op vault get "$VAULT" >/dev/null 2>&1; then
  op vault create "$VAULT" \
    --description "Secrets for the Honeybot Slack agent (managed by hermes service account)"
fi

echo "==> creating seed items (empty values; fill in via 1Password UI or CLI) ..."

# Anthropic
op item get "Anthropic API" --vault "$VAULT" >/dev/null 2>&1 || \
  op item create \
    --category "API Credential" \
    --vault "$VAULT" \
    --title "Anthropic API" \
    'api_key[password]=REPLACE_WITH_ANTHROPIC_KEY'

# Slack Bot
op item get "Slack Bot" --vault "$VAULT" >/dev/null 2>&1 || \
  op item create \
    --category "API Credential" \
    --vault "$VAULT" \
    --title "Slack Bot" \
    'bot_token[password]=xoxb-REPLACE' \
    'app_token[password]=xapp-REPLACE' \
    'signing_secret[password]=REPLACE' \
    'allowed_user_ids[text]=U_MICHELLE_ID'

# HubSpot \u2014 empty on purpose. The hubspot skill fills this in at runtime
# when Michelle pastes her PAK in Slack DM.
op item get "HubSpot" --vault "$VAULT" >/dev/null 2>&1 || \
  op item create \
    --category "API Credential" \
    --vault "$VAULT" \
    --title "HubSpot" \
    'personal_access_key[password]='

echo ""
echo "Seed items created in vault '${VAULT}'. Next:"
echo "  - 1Password web UI > fill in REPLACE values for 'Anthropic API' and 'Slack Bot'"
echo "  - Create the 'honeybot-hermes-ec2' service account and scope it to this vault"
echo "  - Save the ops_... token as OP_SERVICE_ACCOUNT_TOKEN in ./op.env (chmod 600)"
