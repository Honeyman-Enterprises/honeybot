#!/usr/bin/env bash
# connect.sh — first-time per-user Gmail OAuth setup. Two steps:
#
#   1. Generate auth URL (user opens it, approves, copies redirected URL):
#        ./connect.sh --auth-url --user UID
#
#   2. Exchange the auth code for a refresh token, store in 1Password:
#        ./connect.sh --auth-code "<URL or code>" --user UID
#
# Prereq: the user has already created `op://Honeybot/Gmail-{UID}` with
# `client_id`, `client_secret`, and (optionally) `email` fields populated.
# This script reads those, drives the OAuth dance, and writes back the
# `refresh_token` and `scopes` fields.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" && pwd)"
CREDS="$LIB_DIR/creds.sh"

# Default scopes — read + send + modify (label changes). No Calendar/Drive —
# this skill is Gmail-only. Add scopes by editing this list and re-running
# the connect flow; old tokens won't have new scopes until re-consented.
SCOPES=(
  "https://www.googleapis.com/auth/gmail.readonly"
  "https://www.googleapis.com/auth/gmail.send"
  "https://www.googleapis.com/auth/gmail.modify"
)

REDIRECT_URI="http://localhost:1"

usage() {
  cat >&2 <<'USAGE'
usage:
  connect.sh --auth-url  [--user UID]
  connect.sh --auth-code "<URL or raw code>" [--user UID]

Both forms require either $HONEYBOT_SLACK_USER or --user UID. The vault
item op://Honeybot/Gmail-{UID} must already exist with client_id and
client_secret fields.
USAGE
  exit 2
}

mode=""
auth_code_input=""
user_id="${HONEYBOT_SLACK_USER:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth-url) mode="auth-url"; shift ;;
    --auth-code) mode="auth-code"; auth_code_input="${2:-}"; shift 2 ;;
    --user) user_id="${2:-}"; shift 2 ;;
    --user=*) user_id="${1#--user=}"; shift ;;
    -h|--help) usage ;;
    *) echo "connect.sh: unknown arg: $1" >&2; usage ;;
  esac
done

[[ -z "$mode" ]] && usage

if [[ -z "$user_id" ]]; then
  echo "connect.sh: refusing to run without a Slack user ID. Set HONEYBOT_SLACK_USER or pass --user UID." >&2
  exit 2
fi

if ! [[ "$user_id" =~ ^[UW][A-Z0-9]{8,}$ ]]; then
  echo "connect.sh: '$user_id' does not look like a Slack user ID." >&2
  exit 2
fi

# Read client credentials (must already be in vault)
if ! client_id="$("$CREDS" Gmail client_id --user "$user_id" 2>/tmp/.connect-err)"; then
  cat /tmp/.connect-err >&2
  rm -f /tmp/.connect-err
  cat >&2 <<EOF

Vault item op://Honeybot/Gmail-${user_id} either doesn't exist or is missing
the client_id field. Create it first:

  op item create --vault Honeybot --category=login \\
    --title="Gmail-${user_id}" \\
    client_id="<your_client_id>" \\
    client_secret="<your_client_secret>" \\
    email="<your_gmail_address>"
EOF
  exit 3
fi
rm -f /tmp/.connect-err
client_secret="$("$CREDS" Gmail client_secret --user "$user_id")"

scope_param="$(IFS=' '; echo "${SCOPES[*]}")"

case "$mode" in
  auth-url)
    # urlencode scope and redirect
    encoded_scope="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$scope_param")"
    encoded_redirect="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$REDIRECT_URI")"
    cat <<EOF
https://accounts.google.com/o/oauth2/v2/auth?response_type=code&client_id=${client_id}&redirect_uri=${encoded_redirect}&scope=${encoded_scope}&access_type=offline&prompt=consent
EOF
    cat >&2 <<'NOTE'

Open this URL in a browser, sign in to your Google account, approve the
scopes. The browser will fail to load http://localhost:1/?code=... — that
is EXPECTED (there is no local server). Copy the entire address-bar URL
from the failed page and pass it back as:

    connect.sh --auth-code "<the URL you copied>" --user <UID>
NOTE
    ;;

  auth-code)
    [[ -z "$auth_code_input" ]] && usage

    # Accept either a full URL or just a raw code
    if [[ "$auth_code_input" == http* ]]; then
      code="$(python3 -c '
import sys, urllib.parse
url = sys.argv[1]
qs = urllib.parse.urlparse(url).query
params = urllib.parse.parse_qs(qs)
codes = params.get("code", [])
if not codes:
    sys.stderr.write("connect.sh: no ?code= param in URL\n")
    sys.exit(3)
print(codes[0])
' "$auth_code_input")"
    else
      code="$auth_code_input"
    fi

    response="$(curl -sS --fail-with-body -X POST https://oauth2.googleapis.com/token \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "client_id=${client_id}" \
      --data-urlencode "client_secret=${client_secret}" \
      --data-urlencode "code=${code}" \
      --data-urlencode "redirect_uri=${REDIRECT_URI}" \
      --data-urlencode "grant_type=authorization_code" 2>&1)" || {
      echo "connect.sh: code exchange failed:" >&2
      echo "$response" >&2
      exit 3
    }

    refresh_token="$(printf '%s' "$response" | python3 -c '
import json, sys
data = json.load(sys.stdin)
rt = data.get("refresh_token")
if not rt:
    sys.stderr.write("No refresh_token in response. Scope was probably already granted to this client.\n")
    sys.stderr.write("Visit https://myaccount.google.com/permissions, remove the existing grant, then retry --auth-url.\n")
    sys.exit(3)
print(rt)
')"

    granted_scopes="$(printf '%s' "$response" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data.get("scope", ""))
')"

    # Wipe sensitive values from env now that we have what we need
    unset client_secret response code

    # Persist to 1Password
    op item edit "Gmail-${user_id}" --vault Honeybot \
      "refresh_token=${refresh_token}" \
      "scopes=${granted_scopes}" >/dev/null

    unset refresh_token

    echo "connect.sh: Gmail-${user_id} stored. Verifying..." >&2

    # Verify with a tiny request
    bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if "$bin_dir/gmail.sh" --user "$user_id" search "in:inbox" --max 1 >/dev/null 2>&1; then
      echo "connect.sh: OK — Gmail connected for user $user_id." >&2
    else
      echo "connect.sh: WARNING — token stored but verification call failed. Check scopes/API enablement." >&2
      exit 3
    fi
    ;;
esac
