#!/usr/bin/env bash
# _token.sh — mint a short-lived Google OAuth access token for a Slack user
# by exchanging their stored refresh token. Output: bare access token on
# stdout. Errors to stderr, non-zero exit on failure.
#
# Reads:
#   op://Honeybot/Gmail-{UID}/refresh_token
#   op://Honeybot/Gmail-{UID}/client_id
#   op://Honeybot/Gmail-{UID}/client_secret
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

# creds.sh will fail closed if no user is set
refresh_token="$("$CREDS" Gmail refresh_token "${user_arg[@]}")"
client_id="$("$CREDS" Gmail client_id "${user_arg[@]}")"
client_secret="$("$CREDS" Gmail client_secret "${user_arg[@]}")"

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
