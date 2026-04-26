#!/usr/bin/env bash
# _token.sh — mint a short-lived Google OAuth access token for a Slack user
# by exchanging their stored refresh token. Output: bare access token on
# stdout. Errors to stderr, non-zero exit on failure.
#
# Identity model:
#   The user's refresh token is per-user, stored at:
#     op://Honeybot/Gmail-{UID}/refresh_token
#
#   The OAuth client_id/client_secret are SHARED across all users, stored at:
#     op://Honeybot/GoogleOAuth/{client_id,client_secret}
#
#   This is intentional: the OAuth client is a property of the bot/app, not
#   the human. Per-user OAuth clients caused enormous setup friction (each
#   person had to spin up their own GCP project) and gave us nothing extra.
#   Per-user refresh tokens are still per-user — that's the privacy boundary.
#
# Legacy fallback:
#   For users who connected via the old per-user-GCP-project flow (where
#   client_id/client_secret were stored at op://Honeybot/Gmail-{UID}/), we
#   still honor those values when present. Detection: if the per-user
#   client_id field starts with "shared:GoogleOAuth", use the shared creds;
#   otherwise use the per-user values.
#
# Usage:
#   access_token="$(./_token.sh)"             # uses $HONEYBOT_SLACK_USER
#   access_token="$(./_token.sh --user UID)"

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" && pwd)"
CREDS="$LIB_DIR/creds.sh"

user_arg=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) user_arg=(--user "$2"); shift 2 ;;
    --user=*) user_arg=("$1"); shift ;;
    *) echo "_token.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Always per-user: refresh token
refresh_token="$("$CREDS" Gmail refresh_token "${user_arg[@]}")"

# Determine OAuth client creds source: shared (default) or legacy per-user
per_user_client_id="$("$CREDS" Gmail client_id "${user_arg[@]}" 2>/dev/null || true)"

if [[ "$per_user_client_id" == "shared:GoogleOAuth" || -z "$per_user_client_id" ]]; then
  # Shared client — bot-level GoogleOAuth item
  client_id="$(op read 'op://Honeybot/GoogleOAuth/client_id')"
  client_secret="$(op read 'op://Honeybot/GoogleOAuth/client_secret')"
else
  # Legacy per-user client (pre-shared-creds users)
  client_id="$per_user_client_id"
  client_secret="$("$CREDS" Gmail client_secret "${user_arg[@]}")"
fi

response="$(curl -sS --fail-with-body -X POST https://oauth2.googleapis.com/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=${client_id}" \
  --data-urlencode "client_secret=${client_secret}" \
  --data-urlencode "refresh_token=${refresh_token}" \
  --data-urlencode "grant_type=refresh_token" 2>&1)" || {
  echo "_token.sh: token exchange failed:" >&2
  echo "$response" >&2
  exit 3
}

# Wipe sensitive values from env immediately
unset refresh_token client_secret

access_token="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' 2>/dev/null || true)"

if [[ -z "$access_token" ]]; then
  echo "_token.sh: response did not contain access_token:" >&2
  echo "$response" >&2
  exit 3
fi

printf '%s' "$access_token"
