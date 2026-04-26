#!/usr/bin/env bash
# creds.sh — read a per-user secret from 1Password, keyed on the requesting
# Slack user's ID.
#
# Every skill that touches a human's external service (Gmail, AWS, HubSpot,
# Calendar, etc.) MUST route its credential reads through this helper. It is
# the only place that knows the vault naming convention and the only place
# that enforces "no Slack user ID = no credentials".
#
# Usage:
#   creds.sh <Service> <field> [--user SLACK_UID]
#
#   If --user is omitted, the value of $HONEYBOT_SLACK_USER is used. If
#   neither is set, the command fails (exit 2) without touching the vault.
#
# Output:
#   The resolved secret, printed to stdout with no trailing newline. Nothing
#   else goes to stdout. Errors and status go to stderr.
#
# Exit codes:
#   0   success, secret printed to stdout
#   2   usage error (missing service/field or user ID)
#   3   vault lookup failed (item missing, field missing, op error)
#
# Examples:
#   PAK="$(creds.sh HubSpot personal_access_key)"        # uses $HONEYBOT_SLACK_USER
#   export AWS_ACCESS_KEY_ID="$(creds.sh AWS access_key_id --user U04ERIC)"
#   RT="$(creds.sh Gmail refresh_token)" || exit 3

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: creds.sh <Service> <field> [--user SLACK_UID]

  Service  vault item prefix (Gmail, AWS, HubSpot, Slack, ...)
  field    1Password field name within the item
  --user   override the Slack user ID (default: $HONEYBOT_SLACK_USER)
USAGE
  exit 2
}

service="${1:-}"
field="${2:-}"
shift 2 2>/dev/null || usage

[[ -z "$service" || -z "$field" ]] && usage

user_id="${HONEYBOT_SLACK_USER:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) user_id="${2:-}"; shift 2 ;;
    --user=*) user_id="${1#--user=}"; shift ;;
    *) echo "creds.sh: unknown arg: $1" >&2; usage ;;
  esac
done

# Fallback: when running under the Hermes gateway, the requesting user's
# Slack ID is captured per-message by the honeybot-identity hook
# (hooks/honeybot-identity/handler.py) and written to a per-session
# sidecar file keyed on $HERMES_SESSION_KEY. We read that here so skills
# don't have to be invoked with --user every time and so we don't race
# concurrent Slack messages on os.environ.
#
# Precedence (highest first):
#   1. --user UID            (explicit, debug/admin)
#   2. $HONEYBOT_SLACK_USER  (CLI/local-dev override in op.env)
#   3. sidecar file          (gateway path — the production case)
#
# The sidecar path mirrors hooks/honeybot-identity/handler.py:
#   /tmp/honeybot-identity/{session_key_with_colons_as_underscores}/HONEYBOT_SLACK_USER
if [[ -z "$user_id" && -n "${HERMES_SESSION_KEY:-}" ]]; then
  safe_key="${HERMES_SESSION_KEY//:/_}"
  safe_key="${safe_key//\//_}"
  sidecar="/tmp/honeybot-identity/${safe_key}/HONEYBOT_SLACK_USER"
  if [[ -r "$sidecar" ]]; then
    user_id="$(<"$sidecar")"
    user_id="${user_id//[$'\t\r\n ']}"   # strip whitespace just in case
  fi
fi

if [[ -z "$user_id" ]]; then
  cat >&2 <<'ERR'
creds.sh: refusing to read credentials without a Slack user ID.
         Set HONEYBOT_SLACK_USER, pass --user UID, or run under the
         Hermes gateway with the honeybot-identity hook installed
         (hooks/honeybot-identity/).
         This is a hard requirement of the identity model — no default user.
ERR
  exit 2
fi

# Slack user IDs are [UW][A-Z0-9]{8,} — reject anything that clearly isn't one
# before we go building a vault path out of untrusted input.
if ! [[ "$user_id" =~ ^[UW][A-Z0-9]{8,}$ ]]; then
  echo "creds.sh: '$user_id' does not look like a Slack user ID; refusing." >&2
  exit 2
fi

vault_path="op://Honeybot/${service}-${user_id}/${field}"

if ! secret="$(op read "$vault_path" 2>/tmp/.creds-err)"; then
  err="$(cat /tmp/.creds-err 2>/dev/null || true)"
  rm -f /tmp/.creds-err
  echo "creds.sh: could not read ${vault_path}" >&2
  [[ -n "$err" ]] && echo "creds.sh: op said: $err" >&2
  exit 3
fi
rm -f /tmp/.creds-err

printf '%s' "$secret"
