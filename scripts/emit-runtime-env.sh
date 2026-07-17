#!/usr/bin/env sh
# emit-runtime-env.sh — write the compose-level runtime env file.
#
# Context: some containers in docker-compose.yml are upstream images
# (elasticsearch, neo4j) that don't know how to resolve op(...) refs
# themselves. Their passwords live in 1Password, but compose's env_file:
# directive wants a plain key=value file on the host filesystem.
#
# This script runs inside the `secrets-init` compose service (same image
# as honeybot, so it has the op CLI and the service account token). It
# reads the handful of values those upstream containers need and writes
# them to a bind-mounted path on the host (/repo/.env.runtime).
#
# The resulting file is treated exactly like op.env: gitignored,
# dockerignored, chmod 600. It is regenerated from scratch on every
# compose run, so rotating a value in 1Password + `docker compose up -d`
# is the rotation workflow.
#
# Scope is deliberately tight: ONLY the values that compose needs to
# interpolate into a non-Varlock-aware container. Bot-level secrets that
# get consumed by the honeybot container itself stay resolved via
# varlock inside the container — they do NOT go in this file.
#
# Usage: emit-runtime-env.sh <output-path>
#   Typically invoked as: emit-runtime-env.sh /repo/.env.runtime

set -eu

OUT="${1:-/repo/.env.runtime}"

log()  { printf 'emit-runtime-env: %s\n' "$*"; }
warn() { printf 'emit-runtime-env: WARN: %s\n' "$*" >&2; }
die()  { printf 'emit-runtime-env: FATAL: %s\n' "$*" >&2; exit 1; }

# Catastrophic conditions still abort — without these we couldn't read
# anything, full stop.
[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || \
  die "OP_SERVICE_ACCOUNT_TOKEN not set"
command -v op >/dev/null 2>&1 || die "op CLI missing"

OUT_DIR="$(dirname "$OUT")"
[ -d "$OUT_DIR" ] || die "output directory $OUT_DIR does not exist (bind mount missing?)"

TMP="${OUT}.tmp"

# Per-secret resolution is BEST-EFFORT, not fail-closed. Missing or empty
# values are logged as warnings and emitted as empty assignments, so the
# downstream service can decide how to handle the gap on its own.
#
# Rationale: a single missing secret should localize damage to the one
# subsystem that needs it (e.g. Elasticsearch fails to start), not bring
# down secrets-init and cascade into honeybot/hermes, which doesn't even
# need ES/Neo4j to come up. The previous fail-closed behavior took the
# whole stack down whenever a vault item was empty or shadowed by a
# duplicate.
#
# Track whether anything was missing so we can summarize at the end.
MISSING_COUNT=0
read_or_warn() {
  ref="$1"
  val="$(op read "$ref" 2>/dev/null || true)"
  if [ -z "$val" ]; then
    warn "empty/missing: $ref (downstream service will not start)"
    MISSING_COUNT=$((MISSING_COUNT + 1))
  fi
  printf '%s' "$val"
}

# read_or_silent — same as read_or_warn but for OPTIONAL values where
# missing is fine (e.g. a notification webhook the operator may not have
# set up yet). No warn, no MISSING_COUNT bump.
read_or_silent() {
  ref="$1"
  op read "$ref" 2>/dev/null || true
}

ELASTIC_PASSWORD="$(read_or_warn 'op://Honeybot/Elasticsearch/password')"
NEO4J_AUTH="$(read_or_warn 'op://Honeybot/Neo4j/auth')"

# Open WebUI session signing key + the bearer Open WebUI uses to call
# Hermes' api_server. docker-compose.yml does NOT set these in the
# openwebui `environment:` block — env_file (.env.runtime) is the sole
# source. This script emits the exact var names Open WebUI expects
# (OPENAI_API_KEY, WEBUI_SECRET_KEY) so no Compose ${} remapping is
# needed.
#
# Fail-soft (read_or_warn): if these are missing in 1Password, openwebui
# will still boot but won't function — surfaces the misconfiguration in
# the secrets-init log instead of taking the whole stack down at boot.
OPENWEBUI_SECRET_KEY="$(read_or_warn 'op://Honeybot/OpenWebUI/secret_key')"
API_SERVER_KEY="$(read_or_warn 'op://Honeybot/HermesAPI/key')"

# Open WebUI "Login with Google" (OIDC). Optional — empty means the Google
# button doesn't render and Open WebUI still boots, so read_or_silent (no
# warning, no missing-count bump). Item is GoogleOAuth-OpenWebUI (distinct
# from op://Honeybot/GoogleOAuth/ used by the Gmail CLI's Desktop client);
# it MUST be a Google Cloud *Web application* client with the redirect URI
# https://honeybot.honeymanenterprises.com/oauth/google/callback registered.
# NB the secret field is named `secret_id`. See docs/openwebui-google-oauth.md.
GOOGLE_CLIENT_ID="$(read_or_silent 'op://Honeybot/GoogleOAuth-OpenWebUI/client_id')"
GOOGLE_CLIENT_SECRET="$(read_or_silent 'op://Honeybot/GoogleOAuth-OpenWebUI/secret_id')"

# Voice-relay self-hosted MCP OAuth server (Google upstream). Empty = the
# OAuth server stays dormant and MCP falls back to the static voice-token
# bearer, so read_or_silent. Item is a THIRD Google *Web* client (redirect
# https://voice.honeybot.honeymanenterprises.com/oauth/callback). See
# docs/voice-relay-oauth.md.
VOICE_OAUTH_GOOGLE_CLIENT_ID="$(read_or_silent 'op://Honeybot/GoogleOAuth-VoiceRelay/client_id')"
VOICE_OAUTH_GOOGLE_CLIENT_SECRET="$(read_or_silent 'op://Honeybot/GoogleOAuth-VoiceRelay/secret_id')"

# SMTP — consumed by the openwebui service for password-reset / email
# verification flows (and any future surface that wants to send mail; see
# skills/honeybot-dev/references/smtp-plan.md). Open WebUI is not Varlock-
# aware, so its SMTP envs come through .env.runtime via env_file rather
# than via varlock-resolved process env. read_or_warn so a missing SMTP
# entry in the vault degrades to "no outbound mail" instead of taking
# secrets-init down — the Open WebUI container will boot, just without
# functional email. Same fail-soft posture as ES/Neo4j above.
SMTP_HOST="$(read_or_warn 'op://Honeybot/SMTP/host')"
SMTP_PORT="$(read_or_warn 'op://Honeybot/SMTP/port')"
SMTP_USERNAME="$(read_or_warn 'op://Honeybot/SMTP/username')"
SMTP_PASSWORD="$(read_or_warn 'op://Honeybot/SMTP/app_password')"
SMTP_MAIL_FROM="$(read_or_warn 'op://Honeybot/SMTP/mail_from')"
# Display name is purely cosmetic — silent if missing, defaults applied
# downstream in docker-compose.yml.
SMTP_MAIL_FROM_NAME="$(read_or_silent 'op://Honeybot/SMTP/mail_from_name')"

# Open WebUI voice (STT + TTS). The audio layer talks DIRECTLY to OpenAI
# (base URLs set in compose), so it needs the REAL OpenAI key — the same
# one honeybot uses for vision — NOT the api_server bearer that
# OPENAI_API_KEY carries for Open WebUI's chat calls. read_or_silent:
# empty ⇒ voice disabled, Open WebUI still boots. See docs/openwebui-voice.md.
AUDIO_OPENAI_API_KEY="$(read_or_silent 'op://Honeybot/OpenAI/key')"

# Voice relay — consumed by the voice-relay sidecar (not Varlock-aware),
# so its secrets come through .env.runtime like ES/Neo4j/openwebui.
#   SLACK_BOT_TOKEN : DM the requester on late completion (bot token,
#                     same value honeybot uses via varlock).
#   VOICE_TOKEN_MAP : per-user token→Slack-UID JSON (fail-closed if empty;
#                     the relay 401s every request until populated).
#   HONEYBOT_API_KEY: bearer the relay presents to honeybot's api_server —
#                     the same HermesAPI key openwebui uses (API_SERVER_KEY
#                     above). Emitted under the name the relay expects.
# read_or_silent for the token map (empty is a valid resting state);
# read_or_warn for the Slack token (relay can't DM without it).
SLACK_BOT_TOKEN="$(read_or_warn 'op://Honeybot/Slack Bot/bot_token')"
VOICE_TOKEN_MAP="$(read_or_silent 'op://Honeybot/Voice/token_map')"
# admin_key: honeybot's voice-token skill presents this to the relay's
# /admin/tokens endpoint. read_or_warn — without it, live token pushes
# fail (minted tokens only go live on the next full compose up).
VOICE_ADMIN_KEY="$(read_or_warn 'op://Honeybot/Voice/admin_key')"

# Write atomically so partial writes can't confuse compose. Empty values
# are emitted as `KEY=` so compose's env_file parser doesn't choke; the
# downstream container sees an empty env var and fails its own startup
# in isolation.
#
# IMPORTANT — env var naming for Open WebUI:
#
# Open WebUI is a non-Varlock-aware third-party image. Its `env_file:`
# entry in docker-compose.yml points here. Previously, compose's
# `environment:` block tried to remap internal names (API_SERVER_KEY →
# OPENAI_API_KEY, OPENWEBUI_SECRET_KEY → WEBUI_SECRET_KEY, SMTP_MAIL_FROM
# → SMTP_FROM_EMAIL) via ${} interpolation — but Compose evaluates ${}
# against the host shell at parse time, NOT against env_file contents at
# runtime. That meant every ${VAR:-fallback} resolved to the fallback
# (typically an empty string or a literal "from-env-file"), and the real
# value from .env.runtime was shadowed by the broken override.
#
# Fix: emit the EXACT env var names each downstream container expects.
# The `environment:` block in compose no longer sets any of these —
# env_file is the sole source.
#
# Open WebUI expects: OPENAI_API_KEY, WEBUI_SECRET_KEY, SMTP_FROM_EMAIL,
#                     SMTP_FROM_NAME (not SMTP_MAIL_FROM / SMTP_MAIL_FROM_NAME)
umask 077
{
  printf '# Generated by scripts/emit-runtime-env.sh. Do not edit by hand.\n'
  printf '# Regenerated on every compose up via the secrets-init service.\n'

  # ---- Elasticsearch / Neo4j (internal services) ----
  printf 'ELASTIC_PASSWORD=%s\n' "$ELASTIC_PASSWORD"
  printf 'NEO4J_AUTH=%s\n' "$NEO4J_AUTH"

  # ---- Hermes api_server bearer (consumed by honeybot via varlock AND
  #      by openwebui via env_file as the distinct vars each expects) ----
  printf 'API_SERVER_KEY=%s\n' "$API_SERVER_KEY"

  # ---- Open WebUI secrets ----
  # OPENAI_API_KEY: the bearer Open WebUI sends to Hermes' api_server.
  # This is the HermesAPI key, NOT the OpenAI (GPT) key. The honeybot
  # container gets its own OPENAI_API_KEY from varlock (the real OpenAI
  # key for vision fallback); this file is only consumed by openwebui,
  # elasticsearch, neo4j, and redeploy — none of which need the GPT key.
  printf 'OPENAI_API_KEY=%s\n' "$API_SERVER_KEY"
  # WEBUI_SECRET_KEY: signs Open WebUI's own session JWTs.
  printf 'WEBUI_SECRET_KEY=%s\n' "$OPENWEBUI_SECRET_KEY"
  # Keep the internal names too — compose's redeploy service and future
  # consumers may reference them directly.
  printf 'OPENWEBUI_SECRET_KEY=%s\n' "$OPENWEBUI_SECRET_KEY"

  # ---- Open WebUI Google OAuth ----
  # Exact var names Open WebUI reads; empty => Google login disabled.
  printf 'GOOGLE_CLIENT_ID=%s\n' "$GOOGLE_CLIENT_ID"
  printf 'GOOGLE_CLIENT_SECRET=%s\n' "$GOOGLE_CLIENT_SECRET"

  # ---- Open WebUI voice (STT + TTS → OpenAI directly) ----
  # Same real OpenAI key for both; empty => voice disabled.
  printf 'AUDIO_STT_OPENAI_API_KEY=%s\n' "$AUDIO_OPENAI_API_KEY"
  printf 'AUDIO_TTS_OPENAI_API_KEY=%s\n' "$AUDIO_OPENAI_API_KEY"

  # ---- voice-relay MCP OAuth (Google upstream) ----
  printf 'VOICE_OAUTH_GOOGLE_CLIENT_ID=%s\n' "$VOICE_OAUTH_GOOGLE_CLIENT_ID"
  printf 'VOICE_OAUTH_GOOGLE_CLIENT_SECRET=%s\n' "$VOICE_OAUTH_GOOGLE_CLIENT_SECRET"

  # ---- SMTP (Open WebUI env var names) ----
  printf 'SMTP_HOST=%s\n' "$SMTP_HOST"
  printf 'SMTP_PORT=%s\n' "$SMTP_PORT"
  printf 'SMTP_USERNAME=%s\n' "$SMTP_USERNAME"
  printf 'SMTP_PASSWORD=%s\n' "$SMTP_PASSWORD"
  # Open WebUI expects SMTP_FROM_EMAIL / SMTP_FROM_NAME (not the
  # 1Password field names SMTP_MAIL_FROM / SMTP_MAIL_FROM_NAME).
  printf 'SMTP_FROM_EMAIL=%s\n' "$SMTP_MAIL_FROM"
  printf 'SMTP_FROM_NAME=%s\n' "$SMTP_MAIL_FROM_NAME"
  # Keep internal names for any future non-OpenWebUI consumer.
  printf 'SMTP_MAIL_FROM=%s\n' "$SMTP_MAIL_FROM"
  printf 'SMTP_MAIL_FROM_NAME=%s\n' "$SMTP_MAIL_FROM_NAME"

  # ---- voice-relay ----
  # SLACK_BOT_TOKEN: the relay DMs the requester on late completion.
  # VOICE_TOKEN_MAP: per-user token→Slack-UID JSON (single line; compact
  #   JSON has no spaces so it survives env_file's line-literal parsing).
  # HONEYBOT_API_KEY: the relay's bearer to honeybot's api_server — same
  #   value as API_SERVER_KEY, emitted under the name the relay reads.
  printf 'SLACK_BOT_TOKEN=%s\n' "$SLACK_BOT_TOKEN"
  printf 'VOICE_TOKEN_MAP=%s\n' "$VOICE_TOKEN_MAP"
  printf 'VOICE_ADMIN_KEY=%s\n' "$VOICE_ADMIN_KEY"
  printf 'HONEYBOT_API_KEY=%s\n' "$API_SERVER_KEY"
} > "$TMP"
mv "$TMP" "$OUT"
chmod 600 "$OUT"

if [ "$MISSING_COUNT" -gt 0 ]; then
  log "wrote $OUT (mode 600) with $MISSING_COUNT missing value(s) — see WARN lines above"
else
  log "wrote $OUT (mode 600)"
fi
# Always exit 0: secrets-init's job is to do its best and let downstream
# services succeed/fail independently.
exit 0
