#!/usr/bin/env bash
# connect.sh — first-time per-user Gmail/Workspace OAuth connect.
#
# Single source of truth for connecting a Slack user to ALL Google Workspace
# services (Gmail, Calendar, Drive, Docs, Sheets, Contacts). Other skills
# should NEVER walk the user through Google Cloud Console setup; this script
# uses the bot-wide shared OAuth client at op://Honeybot/GoogleOAuth.
#
# Modes:
#   1. Generate auth URL:
#        ./connect.sh --auth-url [--user UID] [--services SERVICES]
#      Prints a single line: the URL to send the user. They click, approve,
#      and paste back the redirected URL.
#
#   2. Exchange auth code (full URL or raw code) for refresh token:
#        ./connect.sh --auth-code "<URL or code>" [--user UID]
#      Stores per-user refresh token in 1Password and verifies via Gmail API.
#
# Identity model:
#   - OAuth client (client_id/client_secret/redirect_uri) is SHARED:
#       op://Honeybot/GoogleOAuth/{client_id,client_secret,redirect_uri}
#   - Per-user refresh token is PER-USER:
#       op://Honeybot/Gmail-{UID}/{refresh_token,scopes,email}
#   - The vault item op://Honeybot/Gmail-{UID} stores
#       client_id=shared:GoogleOAuth
#       client_secret=shared:GoogleOAuth
#     as markers so _token.sh knows to use the shared OAuth client.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" && pwd)"
CREDS="$LIB_DIR/creds.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default: full Workspace. Pass --services to narrow.
ALL_SCOPES=(
  "https://www.googleapis.com/auth/gmail.readonly"
  "https://www.googleapis.com/auth/gmail.send"
  "https://www.googleapis.com/auth/gmail.modify"
  "https://www.googleapis.com/auth/calendar"
  "https://www.googleapis.com/auth/calendar.events"
  "https://www.googleapis.com/auth/drive"
  "https://www.googleapis.com/auth/documents"
  "https://www.googleapis.com/auth/spreadsheets"
  "https://www.googleapis.com/auth/contacts"
  "https://www.googleapis.com/auth/contacts.readonly"
  "https://www.googleapis.com/auth/userinfo.email"
  "https://www.googleapis.com/auth/userinfo.profile"
  "openid"
)

usage() {
  cat >&2 <<'USAGE'
usage:
  connect.sh --auth-url  [--user UID]
  connect.sh --auth-code "<URL or raw code>" [--user UID]

Both forms require either $HONEYBOT_SLACK_USER or --user UID. The shared
OAuth client at op://Honeybot/GoogleOAuth must be populated with
client_id, client_secret, and redirect_uri.
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

# Read shared OAuth client creds
client_id="$(op read 'op://Honeybot/GoogleOAuth/client_id')"
client_secret="$(op read 'op://Honeybot/GoogleOAuth/client_secret')"
redirect_uri="$(op read 'op://Honeybot/GoogleOAuth/redirect_uri')"

scope_param="${ALL_SCOPES[*]}"

case "$mode" in
  auth-url)
    encoded_scope="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$scope_param")"
    encoded_redirect="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$redirect_uri")"
    cat <<EOF
https://accounts.google.com/o/oauth2/v2/auth?response_type=code&client_id=${client_id}&redirect_uri=${encoded_redirect}&scope=${encoded_scope}&access_type=offline&prompt=consent&state=${user_id}
EOF
    cat >&2 <<'NOTE'

Send the URL above to the user. They open it, sign in, approve. Their browser
will land on the configured redirect URI (https://honeymanenterprises.com/oauth/honeybot/callback?code=...).
They paste the WHOLE redirected URL back to you, then call:

    connect.sh --auth-code "<the URL they pasted>" --user <UID>

PRIOR-GRANT GOTCHA: If the user has previously connected and you're
reconnecting them, they must first revoke the existing grant at
https://myaccount.google.com/permissions or the new exchange may fail
or yield a stale refresh token.
NOTE
    ;;

  auth-code)
    [[ -z "$auth_code_input" ]] && usage

    # Accept a full URL (with optional HTML-entity-escaped &amp;) or just a raw code.
    # Also extract `state` so we can verify it matches $user_id (hard rule:
    # only the requesting user may auth themselves; we never accept a
    # callback whose state belongs to a different Slack user).
    if [[ "$auth_code_input" == http* ]]; then
      parsed="$(python3 -c '
import sys, urllib.parse, html, json
url = html.unescape(sys.argv[1])
qs = urllib.parse.urlparse(url).query
params = urllib.parse.parse_qs(qs)
codes = params.get("code", [])
states = params.get("state", [])
if not codes:
    sys.stderr.write("connect.sh: no ?code= param in URL\n")
    sys.exit(3)
print(json.dumps({"code": codes[0], "state": states[0] if states else ""}))
' "$auth_code_input")"
      code="$(echo "$parsed" | jq -r .code)"
      state="$(echo "$parsed" | jq -r .state)"
    else
      code="$auth_code_input"
      state=""
    fi

    # HARD RULE: state in callback must equal the Slack user who is connecting.
    # This prevents:
    #  - User A pasting User B's callback URL into the bot
    #  - URL forwarding / share-screen leaks across users
    #  - Stale URLs from prior sessions binding to the wrong identity
    # When state is missing (raw-code mode), require explicit --user and skip.
    if [[ -n "$state" && "$state" != "$user_id" ]]; then
      echo "connect.sh: REFUSING — callback state ($state) does not match the Slack user requesting auth ($user_id)." >&2
      echo "connect.sh: Only the user being connected may complete their own OAuth flow. Have $state run --auth-url for themselves." >&2
      exit 4
    fi

    # Exchange code for tokens, write response to a temp file (NOT stdout).
    # IMPORTANT: stdout/stderr from terminal-based callers may apply secret
    # redaction to token-shaped strings, mangling the value before persistence.
    # We keep the entire exchange + persist + verify pipeline INSIDE a single
    # bash invocation so tokens never cross a shell-output boundary.
    tmp="$(mktemp /tmp/.gtokresp.XXXXXX)"
    trap 'rm -f "$tmp"' EXIT

    if ! curl -sS --fail-with-body -X POST https://oauth2.googleapis.com/token \
          -H "Content-Type: application/x-www-form-urlencoded" \
          --data-urlencode "client_id=${client_id}" \
          --data-urlencode "client_secret=${client_secret}" \
          --data-urlencode "code=${code}" \
          --data-urlencode "redirect_uri=${redirect_uri}" \
          --data-urlencode "grant_type=authorization_code" \
          -o "$tmp"; then
      echo "connect.sh: code exchange failed:" >&2
      cat "$tmp" >&2
      exit 3
    fi

    if grep -q '"error"' "$tmp"; then
      echo "connect.sh: code exchange returned error:" >&2
      cat "$tmp" >&2
      exit 3
    fi

    # Pull values into shell vars via jq (jq output stays in shell — never
    # echoed to stdout, never round-tripped through Python tooling boundaries)
    rt="$(jq -r .refresh_token "$tmp")"
    sc="$(jq -r .scope "$tmp")"
    at="$(jq -r .access_token "$tmp")"

    if [[ -z "$rt" || "$rt" == "null" ]]; then
      echo "connect.sh: no refresh_token in response. The user likely already has an active grant." >&2
      echo "connect.sh: ask them to revoke at https://myaccount.google.com/permissions then retry." >&2
      exit 3
    fi

    # Sanity-check refresh token length. Real Google refresh tokens are 100+ chars.
    if [[ "${#rt}" -lt 50 ]]; then
      echo "connect.sh: refresh_token suspiciously short (${#rt} chars). Aborting." >&2
      exit 3
    fi

    # Look up the user's email by calling userinfo with the access token —
    # so we can store it in the vault item for display.
    email="$(curl -sS -H "Authorization: Bearer $at" \
              https://www.googleapis.com/oauth2/v3/userinfo | jq -r .email)"

    # Cross-user contamination guard: if this Slack user already has an email
    # on file (from a prior connect), the email from this consent MUST match.
    # Otherwise we'd be storing User A's Google account under User B's Slack ID.
    title="Gmail-${user_id}"
    existing_email="$(op read "op://Honeybot/Gmail-${user_id}/email" 2>/dev/null || true)"
    if [[ -n "$existing_email" && "$existing_email" != "$email" ]]; then
      echo "connect.sh: REFUSING to store — Slack user $user_id has $existing_email on file but you connected as $email." >&2
      echo "connect.sh: This is the cross-user contamination guard. If $existing_email is wrong, an admin must clear the vault item first." >&2
      exit 4
    fi

    # Create the vault item if it doesn't exist; otherwise edit in place.
    if op item get "$title" --vault Honeybot --format json >/dev/null 2>&1; then
      op item edit "$title" --vault Honeybot \
        "refresh_token=$rt" "scopes=$sc" "email=$email" \
        "client_id=shared:GoogleOAuth" "client_secret=shared:GoogleOAuth" \
        >/dev/null
    else
      op item create --vault Honeybot --category=login \
        --title="$title" \
        "refresh_token=$rt" "scopes=$sc" "email=$email" \
        "client_id=shared:GoogleOAuth" "client_secret=shared:GoogleOAuth" \
        >/dev/null
    fi

    # Wipe sensitive locals
    unset rt at client_secret

    # Verify by minting a fresh access token and hitting the Gmail profile endpoint
    if "$BIN_DIR/gmail.sh" --user "$user_id" search "in:inbox" --max 1 >/dev/null 2>&1; then
      echo "connect.sh: OK — Google Workspace connected for $email (user $user_id)." >&2
    else
      echo "connect.sh: WARNING — token stored but verification call failed. Check scopes/API enablement." >&2
      exit 3
    fi
    ;;
esac
