#!/usr/bin/env bash
# send-email.sh — thin shell wrapper around send_email.py.
#
# Lets shell skills send mail without rebuilding their own SMTP client. The
# Python module is the source of truth — this wrapper exists only so shell
# skills don't need to know about the file path or the python3 invocation.
#
# Same env contract: reads SMTP_* env vars resolved by varlock from
# op://Honeybot/SMTP/*. Same exit codes as send_email.py:
#   0 sent | 2 usage | 4 not configured | 5 send failed
#
# Usage:
#   send-email.sh --to ADDR --subject TEXT --body TEXT
#                 [--html HTML] [--reply-to ADDR] [--from-name NAME]
#
#   With --body omitted, body is read from stdin:
#     send-email.sh --to user@example.com --subject "hi" <<<"hello"
#
# Examples:
#   # plain text
#   send-email.sh --to "$EMAIL" --subject "Verify" \
#     --body "Click https://honeybot.example/verify?t=$TOKEN to confirm."
#
#   # html alternative (text fallback required)
#   send-email.sh --to "$EMAIL" --subject "Verify" \
#     --body "Open: $LINK" \
#     --html "<a href=\"$LINK\">Click to verify</a>"
#
# Discoverability: this script lives at ${HOME}/.hermes/skills/_lib/ inside
# the container (COPY'd from skills/_lib/ at image build). Skills should
# call it as ../_lib/send-email.sh from their own bin/ directory, NOT by
# absolute path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/send_email.py" "$@"
