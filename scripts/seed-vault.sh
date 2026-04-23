#!/usr/bin/env sh
# seed-vault.sh — idempotently ensure every 1Password item referenced by
# .env.schema exists in the Honeybot vault.
#
# Runs INSIDE the honeybot container on every boot, before `varlock run`.
# Uses OP_SERVICE_ACCOUNT_TOKEN only. No human signin. No vault creation.
#
# Prerequisites (done ONCE manually in the 1Password web UI):
#   1. Create the "Honeybot" vault.
#   2. Create a service account "honeybot-hermes-ec2" scoped to that vault
#      with `read_items` + `write_items`.
#   3. Put the `ops_...` token into ./op.env at the repo root.
#
# On every boot this script:
#   - creates missing items with placeholder fields so op() resolution
#     always returns a value (empty string for non-required, auto-generated
#     secrets for internal-only services).
#   - leaves existing items untouched.
#   - fails the container fast if the vault is unreachable.
#
# @required items that need human-supplied values (Anthropic key, Slack
# tokens, Mem0 key, AWS creds) are created EMPTY here. Varlock then fails
# closed at container run until a human fills them in 1Password. That's
# by design — the bot refuses to start with missing real credentials.
#
# Edge case: if an existing item is missing a field referenced by the
# schema (partial manual creation), this script will skip it and varlock
# will 404 at resolve time. Fix: delete the partial item in 1Password and
# let the next boot recreate it cleanly.

set -eu

VAULT="${HONEYBOT_VAULT:-Honeybot}"

log() { printf 'seed-vault: %s\n' "$*"; }
die() { printf 'seed-vault: FATAL: %s\n' "$*" >&2; exit 1; }

[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || \
  die "OP_SERVICE_ACCOUNT_TOKEN is not set (expected via ./op.env)"

command -v op >/dev/null 2>&1 || die "op CLI not in image"
command -v jq >/dev/null 2>&1 || die "jq not in image"

# Sanity check: token authenticates AND the vault is in scope.
if ! op vault get "$VAULT" >/dev/null 2>&1; then
  die "cannot access '$VAULT' vault with this service account token"
fi

# One API call to enumerate existing items, then O(1) membership checks.
# Cheaper than N `op item get` probes and much faster on cold boot.
EXISTING="$(op item list --vault "$VAULT" --format json 2>/dev/null \
  | jq -r '.[].title' || true)"

item_exists() {
  # grep -Fx: fixed string, full-line match (avoids partial-name collisions).
  printf '%s\n' "$EXISTING" | grep -Fx "$1" >/dev/null 2>&1
}

ensure_item() {
  title="$1"; shift
  category="$1"; shift
  if item_exists "$title"; then
    log "[skip]   $title"
    return 0
  fi
  log "[create] $title"
  op item create \
    --category "$category" \
    --vault "$VAULT" \
    --title "$title" \
    "$@" >/dev/null
}

# Internal-only secrets auto-generate on first creation. No human involved.
gen_pw() {
  bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "$bytes"
  else
    head -c "$bytes" /dev/urandom | base64 | tr -d '\n'
  fi
}

# ---------------------------------------------------------------------------
# Required items that need human-supplied values (empty at create; varlock
# fails closed at run until humans fill them in the 1Password UI).
# ---------------------------------------------------------------------------
ensure_item "Anthropic API" "API Credential" \
  'api_key[password]='

ensure_item "Mem0" "API Credential" \
  'key[password]='

ensure_item "Slack Bot" "API Credential" \
  'bot_token[password]=' \
  'app_token[password]=' \
  'signing_secret[password]=' \
  'allowed_user_ids[text]='

ensure_item "AWS" "API Credential" \
  'access_key_id[password]=' \
  'secret_access_key[password]=' \
  'default_region[text]=us-east-1'

# ---------------------------------------------------------------------------
# Runtime-filled by skills (empty placeholder is the intended resting state).
# ---------------------------------------------------------------------------
ensure_item "HubSpot" "API Credential" \
  'personal_access_key[password]='

# ---------------------------------------------------------------------------
# Internal-only @required secrets — auto-generated on first creation so the
# container doesn't fail closed on its own infra dependencies.
# ---------------------------------------------------------------------------
ensure_item "Elasticsearch" "API Credential" \
  "password[password]=$(gen_pw 32)"

ensure_item "Neo4j" "API Credential" \
  "auth[password]=neo4j/$(gen_pw 24)"

# ---------------------------------------------------------------------------
# Optional MCP / gateway credentials (empty; non-required in schema).
# ---------------------------------------------------------------------------
for svc in "Exa" "Brave Search" "Tavily" "Fal"; do
  ensure_item "$svc" "API Credential" 'api_key[password]='
done

ensure_item "Sentry"   "API Credential" 'auth_token[password]='
ensure_item "Mercury"  "API Credential" 'api_token[password]='
ensure_item "Telegram" "API Credential" 'token[password]='

ensure_item "Honcho" "API Credential" \
  'api_key[password]=' \
  'base_url[text]='

log "done"
