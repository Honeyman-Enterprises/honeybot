#!/usr/bin/env bash
# smtp-smoke.sh — verify outbound SMTP works end-to-end.
#
# Run this after configuring op://Honeybot/SMTP/* in 1Password and after
# the next `docker compose up -d` (so secrets-init has emitted the SMTP
# vars into .env.runtime). Sends a one-line test email through the
# configured relay; exits 0 on success, 1 on any failure.
#
# Usage:
#   scripts/smtp-smoke.sh <recipient-email>
#
# Reads from process env (set by varlock or by sourcing .env.runtime):
#   SMTP_HOST, SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD,
#   SMTP_MAIL_FROM, SMTP_MAIL_FROM_NAME (optional, defaults "Honeybot").
#
# Implementation: pure stdlib Python (smtplib + STARTTLS + LOGIN auth).
# No msmtp, no swaks, no extra dependency — runs anywhere `python3` does,
# which is everywhere honeybot runs.
#
# Inside the honeybot container:
#   docker exec -it honeybot bash -c \
#     'set -a; . /repo/.env.runtime; set +a; python3 /repo/scripts/smtp-smoke.sh you@example.com'
#
# On the host (Mac), where varlock is the resolver:
#   varlock run -- ./scripts/smtp-smoke.sh you@example.com

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: smtp-smoke.sh <recipient-email>" >&2
  exit 2
fi

RECIPIENT="$1"

# Sanity-check required vars BEFORE handing off to Python so failures
# surface as readable shell errors, not Python tracebacks.
: "${SMTP_HOST:?SMTP_HOST not set (sourced .env.runtime?)}"
: "${SMTP_PORT:?SMTP_PORT not set}"
: "${SMTP_USERNAME:?SMTP_USERNAME not set}"
: "${SMTP_PASSWORD:?SMTP_PASSWORD not set}"
: "${SMTP_MAIL_FROM:?SMTP_MAIL_FROM not set}"
SMTP_MAIL_FROM_NAME="${SMTP_MAIL_FROM_NAME:-Honeybot}"

# Hand off to Python for the actual SMTP transaction. Inline so this
# stays a single self-contained script.
exec python3 - "$RECIPIENT" <<'PYEOF'
import os
import smtplib
import socket
import ssl
import sys
from email.message import EmailMessage
from datetime import datetime, timezone

recipient = sys.argv[1]
host = os.environ["SMTP_HOST"]
port = int(os.environ["SMTP_PORT"])
username = os.environ["SMTP_USERNAME"]
password = os.environ["SMTP_PASSWORD"]
mail_from = os.environ["SMTP_MAIL_FROM"]
mail_from_name = os.environ.get("SMTP_MAIL_FROM_NAME", "Honeybot")

# Build a minimal RFC 5322 message. Using EmailMessage (not the legacy
# email.mime.* classes) so headers get encoded correctly without manual
# RFC 2047 wrapping.
msg = EmailMessage()
msg["From"] = f"{mail_from_name} <{mail_from}>"
msg["To"] = recipient
msg["Subject"] = "honeybot SMTP smoke test"
hostname = socket.gethostname()
ts = datetime.now(timezone.utc).isoformat()
msg.set_content(
    f"This is an automated test from honeybot's scripts/smtp-smoke.sh.\n"
    f"\n"
    f"If you received this, outbound mail through {host}:{port} is working.\n"
    f"\n"
    f"  hostname: {hostname}\n"
    f"  sent at:  {ts}\n"
    f"  envelope: MAIL FROM <{mail_from}>  RCPT TO <{recipient}>\n"
)

print(f"[smtp-smoke] connecting to {host}:{port} as {username} ...", flush=True)
context = ssl.create_default_context()

# Workspace relay is STARTTLS on 587. If a future backend needs SMTPS
# on 465, switch SMTP_SSL here — don't drop TLS.
with smtplib.SMTP(host, port, timeout=30) as smtp:
    smtp.ehlo()
    smtp.starttls(context=context)
    smtp.ehlo()
    smtp.login(username, password)
    print(f"[smtp-smoke] sending to {recipient} ...", flush=True)
    refused = smtp.send_message(msg)
    if refused:
        print(f"[smtp-smoke] FAIL: server refused recipients: {refused}", file=sys.stderr)
        sys.exit(1)

print("[smtp-smoke] OK — message accepted by relay.", flush=True)
PYEOF
