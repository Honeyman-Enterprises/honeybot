#!/usr/bin/env bash
# verify_session.sh — shell wrapper for the OTP identity verification gate.
#
# Called by creds.sh before reading any per-user credential. Also callable
# directly by any script that needs to check auth status.
#
# Uses $HERMES_SESSION_KEY from the environment (set by the Hermes gateway
# in run_sync before tool execution).
#
# Exit codes:
#   0   session is verified (prints JSON to stdout)
#   4   session NOT verified (prints JSON to stdout)
#   2   usage error / missing session key
#
# When sourced as a guard (typical usage):
#   source ~/.hermes/auth/verify_session.sh || exit $?
#   # only reached if session is verified

set -euo pipefail

AUTH_DIR="${HONEYBOT_AUTH_DIR:-$(cd "$(dirname "$0")" && pwd)}"

result="$(python3 "${AUTH_DIR}/verify_session.py" "$@" 2>&1)" || {
    rc=$?
    echo "$result"
    exit $rc
}

echo "$result"
