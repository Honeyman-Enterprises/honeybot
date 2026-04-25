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
# pipefail so a redirect failure in `cmd 2>file | other` aborts. Without
# this, a bad redirect (e.g. unwritable cwd) silently leaves the LHS
# stderr broken, the pipeline returns the RHS's exit, and we'd carry on
# with empty data — historically that caused seed-vault to wipe its
# `EXISTING` set and re-create every item as a duplicate.
( set -o pipefail ) 2>/dev/null && set -o pipefail || true

VAULT="${HONEYBOT_VAULT:-Honeybot}"

# Stderr capture files for op invocations. Always under a tmpdir we own
# (mktemp respects $TMPDIR, default /tmp) — the previous relative path
# `op_list_err.tmp` failed when cwd was /home/honeybot (owned 10001:10001,
# not writable by the dropped UID), which triggered the duplicate-item
# regression described above.
TMP_ERR_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_ERR_DIR"' EXIT

log() { printf 'seed-vault: %s\n' "$*"; }
die() { printf 'seed-vault: FATAL: %s\n' "$*" >&2; exit 1; }

[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || \
  die "OP_SERVICE_ACCOUNT_TOKEN is not set (expected via ./op.env)"

command -v op >/dev/null 2>&1 || die "op CLI not in image"
command -v jq >/dev/null 2>&1 || die "jq not in image"

# Sanity check: token authenticates AND the vault is in scope.
#
# Capture op's stderr instead of redirecting to /dev/null. Earlier versions
# silently swallowed it and printed a hard-coded "cannot access vault"
# message regardless of the real failure (token-scope vs $HOME ownership
# vs network), which was actively misleading during bring-up. Now the
# actual op error surfaces in the FATAL line.
op_err="$(op vault get "$VAULT" 2>&1 >/dev/null)" || \
  die "op vault get '$VAULT' failed:
$op_err"

# Same treatment for the item enumeration: don't drop op's stderr on the
# floor. If the listing fails, fail loud with the real reason — and do
# NOT proceed, because an empty EXISTING would be indistinguishable from
# "vault is empty" and we'd create duplicates of every item.
list_err="$TMP_ERR_DIR/op_list_err"
EXISTING="$(op item list --vault "$VAULT" --format json 2>"$list_err" \
  | jq -r '.[].title')" || \
  die "op item list --vault '$VAULT' failed:
$(cat "$list_err" 2>/dev/null || true)"

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
