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
ensure_item "OpenAI"   "API Credential" 'key[password]='

# BlueBubbles relay (Phase 9 iMessage gateway). server_url is the URL of
# the BlueBubbles Server running on the home Mac mini (e.g. an
# https://<relay-host>:<port> address on the imessage.relay subdomain);
# password is the shared secret configured in BlueBubbles' setup wizard.
# Both must match what the Mac side expects — fill them in 1Password by
# hand after the relay is installed and configured. Empty here disables
# the integration cleanly.
ensure_item "BlueBubbles" "API Credential" \
  'server_url[text]=' \
  'password[password]='

ensure_item "Honcho" "API Credential" \
  'api_key[password]=' \
  'base_url[text]='

# ---------------------------------------------------------------------------
# HermesAPI — bearer key for the Hermes OpenAI-compatible API server.
# ---------------------------------------------------------------------------
# Auto-generated on first creation. The honeybot container reads this via
# API_SERVER_KEY (varlock) and refuses unauthenticated requests at /v1/*.
# Open WebUI (and any other OpenAI-compatible client we add) presents this
# as the Bearer token; container-to-container traffic is on honeynet so
# even pre-auth the surface is small, but we key-gate anyway.
ensure_item "HermesAPI" "API Credential" \
  "key[password]=$(gen_pw 32)"

# ---------------------------------------------------------------------------
# SMTP — outbound mail relay for honeybot. Primary use case is the
# cross-provider identity-linking flow: when a user attaches a new auth
# provider (Google, GitHub, Microsoft, …) to their unified profile, the
# system sends a one-time link to the email that provider asserted, to
# prove the human controls that inbox. Open WebUI's password-reset path
# is a downstream consumer of the same relay, not the reason it exists.
# Full design + L0–L3 contract lives at docs/email-verification.md.
#
# All fields default empty. send_email.send() raises SMTPNotConfigured
# when any required field is empty, and every consumer is required to
# handle that as "feature off" — bot itself boots fine without SMTP.
# Fill in via the 1Password UI when you're ready to enable outbound
# mail; the SES Console click-path is in the design doc.
#
# Backend: AWS SES SMTP. Fill from the SES Console after verifying the
# domain identity and generating SMTP credentials:
#   `host`           = email-smtp.us-east-1.amazonaws.com
#   `port`           = 587  (STARTTLS)
#   `username`       = SES SMTP user (NOT an IAM access key — derived
#                      via SES Console "Create SMTP credentials")
#   `app_password`   = SES SMTP password (same dialog)
#   `mail_from`      = noreply@honeymanenterprises.com (any address in
#                      a verified domain works; doesn't need a mailbox)
#   `mail_from_name` = display name, e.g. "Honeybot"
# ---------------------------------------------------------------------------
ensure_item "SMTP" "API Credential" \
  'host[text]=' \
  'port[text]=' \
  'username[text]=' \
  'app_password[password]=' \
  'mail_from[text]=' \
  'mail_from_name[text]='

# ---------------------------------------------------------------------------
# Voice — per-user token map for the voice-relay sidecar.
# ---------------------------------------------------------------------------
# token_map is a compact JSON object mapping a per-user bearer token to
# that user's Slack UID, e.g.:
#   {"tok_eric_abc123":"U04ERIC","tok_michelle_def456":"U05MICHELLE"}
# The voice-relay reads it (via VOICE_TOKEN_MAP in .env.runtime) to
# authenticate inbound voice requests and to know whom to DM in Slack on
# late completion. Empty (the seeded default) = fail-closed: every voice
# request 401s until you populate it. Generate a token per person (any
# opaque high-entropy string) and put it in their Siri Shortcut / MCP
# config. See docs/voice-relay.md.
#
# admin_key authenticates honeybot's voice-token skill to the relay's
# /admin/tokens endpoint (so a freshly minted token goes live without a
# relay restart). Auto-generated on first creation — no human involved;
# it's an internal service-to-service secret, never exposed to users.
ensure_item "Voice" "API Credential" \
  'token_map[text]=' \
  "admin_key[password]=$(gen_pw 32)"

# ---------------------------------------------------------------------------
# OpenWebUI — secret key for signing its session cookies / JWTs.
# ---------------------------------------------------------------------------
# Open WebUI bakes WEBUI_SECRET_KEY into the JWT signing it uses for its
# own user-account auth (separate from the Hermes API key above — Open
# WebUI has its own multi-user accounts on top of the upstream model).
# Generated once; rotating it logs every Open WebUI user out, so do that
# deliberately, not casually.
ensure_item "OpenWebUI" "API Credential" \
  "secret_key[password]=$(gen_pw 48)"

# ---------------------------------------------------------------------------
# OpenWebUI Google OAuth — "Login with Google" for the Open WebUI frontend.
# ---------------------------------------------------------------------------
# A Google Cloud OAuth 2.0 *Web application* client (distinct from the
# per-user Gmail/Calendar OAuth client at op://Honeybot/GoogleOAuth/, which
# is a Desktop/device client for a different flow). Fill both fields from
# the Google Cloud Console; empty = the Google button just doesn't appear
# and Open WebUI still boots. Redirect URI to register on the client:
#   https://honeybot.honeymanenterprises.com/oauth/google/callback
# See docs/openwebui-google-oauth.md for the click-path.
ensure_item "OpenWebUI Google OAuth" "API Credential" \
  'client_id[text]=' \
  'client_secret[password]='

# ---------------------------------------------------------------------------
# GitHub Bot — GitHub App credentials for the bot's own repo operations.
# ---------------------------------------------------------------------------
# This is a GitHub App (NOT a personal access token). The fields (app_id,
# installation_id, client_id, client_secret) and the attached PEM private
# key are provisioned manually in the GitHub UI and then stored in
# 1Password by hand. They CANNOT be auto-generated.
#
# ensure_item is idempotent (skip-if-exists), so this will never overwrite
# the real item — it only creates an empty placeholder on a truly cold
# deploy so the dependency is documented and discoverable. The bot will
# NOT function for GitHub operations until a human fills in the real
# values and attaches the PEM file in the 1Password UI.
#
# Consumers: honeybot-dev skill (self-PRs), skills/_lib/gh-app-token.sh,
#            and any workflow that pushes to Honeyman-Enterprises repos.
ensure_item "GitHub Bot" "API Credential" \
  'username[text]=' \
  'credential[password]=' \
  'app_id[password]=' \
  'installation_id[password]=' \
  'client_id[text]=' \
  'client_secret[password]='

log "done"
