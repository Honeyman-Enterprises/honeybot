#!/usr/bin/env python3
"""
send_email.py — single-source-of-truth outbound mail sender for honeybot.

Why this exists
---------------
honeybot needs to send transactional email from several places that don't
(and shouldn't) know each other:

  - the cross-provider identity-linking flow proves you own the email
    address you're trying to attach to your unified profile (this is the
    primary driver — see docs/email-verification.md)
  - Open WebUI's account-recovery / verification path, when enabled
  - any future surface that has a legitimate "send the user a one-time
    link" requirement

Every one of those callers reads the SMTP_* env vars (resolved by varlock
from op://Honeybot/SMTP/* at container start) and routes the actual send
through this module. Nobody invents their own SMTP code, nobody creates
their own env names, nobody reaches into 1Password directly. One sender,
one set of env names, one place to add observability / rate limiting /
DKIM later.

Contract
--------
Reads from os.environ (varlock has already populated these):
  SMTP_HOST            relay host (e.g. smtp-relay.gmail.com)
  SMTP_PORT            relay port (e.g. 587 for STARTTLS)
  SMTP_USERNAME        SMTP-AUTH user (a Workspace user with 2-Step on)
  SMTP_PASSWORD        app password generated for that user
  SMTP_MAIL_FROM       envelope From (e.g. noreply@honeyman.enterprises)
  SMTP_MAIL_FROM_NAME  (optional) display name in the From header

CLI:
  send_email.py --to ADDR --subject TEXT --body TEXT
                [--html HTML] [--reply-to ADDR]
                [--from-name NAME]

Library:
  from skills._lib.send_email import send, SMTPNotConfigured
  send(to="user@example.com", subject="Verify", body="Open the link...")

Exit codes (CLI):
  0   sent
  2   usage error (missing required arg)
  4   SMTP not configured (one or more required env vars empty)
  5   send failed (auth, connection, rejection — see stderr)

Stdlib only — no pip dependencies. Stays runnable from cron, from a shell
skill via subprocess, and from any Python skill via direct import.
"""

from __future__ import annotations

import argparse
import os
import smtplib
import socket
import ssl
import sys
from dataclasses import dataclass
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formataddr, formatdate, make_msgid
from typing import Optional


# Env vars that MUST all be set (and non-empty) for any send to be possible.
# SMTP_MAIL_FROM_NAME is intentionally not in this set — display name is
# cosmetic, the envelope From is what counts.
REQUIRED_ENV = (
    "SMTP_HOST",
    "SMTP_PORT",
    "SMTP_USERNAME",
    "SMTP_PASSWORD",
    "SMTP_MAIL_FROM",
)


class SMTPNotConfigured(RuntimeError):
    """Raised when one or more required SMTP_* env vars are empty.

    Callers should treat this as "SMTP feature is off"; it's not a bug,
    it's the documented null state for a host that hasn't been wired
    for outbound mail. Surface a clear message to the end user
    (e.g. "Email verification is not available on this deployment yet")
    rather than retrying.
    """


class SMTPSendError(RuntimeError):
    """Raised when the SMTP transaction fails for any reason post-config.

    Includes the underlying exception as ``__cause__`` so callers can
    distinguish auth failures from connection failures from rejections
    if they care.
    """


@dataclass(frozen=True)
class _Config:
    host: str
    port: int
    username: str
    password: str
    mail_from: str
    mail_from_name: str  # may be ""

    @classmethod
    def from_env(cls) -> "_Config":
        missing = [k for k in REQUIRED_ENV if not os.environ.get(k, "").strip()]
        if missing:
            raise SMTPNotConfigured(
                "SMTP not configured; missing or empty: "
                + ", ".join(missing)
                + ". Populate op://Honeybot/SMTP/* in 1Password to enable."
            )
        try:
            port = int(os.environ["SMTP_PORT"])
        except ValueError as e:
            raise SMTPNotConfigured(
                f"SMTP_PORT={os.environ['SMTP_PORT']!r} is not an integer"
            ) from e
        return cls(
            host=os.environ["SMTP_HOST"].strip(),
            port=port,
            username=os.environ["SMTP_USERNAME"].strip(),
            password=os.environ["SMTP_PASSWORD"],  # don't strip — passwords can have edge whitespace
            mail_from=os.environ["SMTP_MAIL_FROM"].strip(),
            mail_from_name=os.environ.get("SMTP_MAIL_FROM_NAME", "").strip(),
        )


def _build_message(
    cfg: _Config,
    to: str,
    subject: str,
    body: str,
    html: Optional[str],
    reply_to: Optional[str],
    from_name_override: Optional[str],
) -> MIMEMultipart | MIMEText:
    """Build a MIME message, multipart/alternative if html is supplied."""
    display_name = from_name_override or cfg.mail_from_name
    from_header = formataddr((display_name or "", cfg.mail_from))

    if html:
        msg: MIMEMultipart | MIMEText = MIMEMultipart("alternative")
        msg.attach(MIMEText(body, "plain", _charset="utf-8"))
        msg.attach(MIMEText(html, "html", _charset="utf-8"))
    else:
        msg = MIMEText(body, "plain", _charset="utf-8")

    msg["From"] = from_header
    msg["To"] = to
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=cfg.mail_from.split("@", 1)[-1] or None)
    if reply_to:
        msg["Reply-To"] = reply_to
    return msg


def send(
    *,
    to: str,
    subject: str,
    body: str,
    html: Optional[str] = None,
    reply_to: Optional[str] = None,
    from_name: Optional[str] = None,
    timeout_seconds: int = 30,
) -> None:
    """Send a single message via the configured SMTP relay.

    Raises:
        SMTPNotConfigured: required env vars are missing/empty.
        SMTPSendError: connection, auth, or send transaction failed.
        ValueError: trivially-bad inputs (empty to/subject).

    Returns None on success. Idempotency is the caller's job — if you
    re-call this for the same logical event, the recipient gets two
    emails. Verification flows must store an "already sent" marker
    keyed on (recipient, token) before invoking send.
    """
    if not to or not to.strip():
        raise ValueError("to: must be a non-empty address")
    if not subject:
        raise ValueError("subject: must be non-empty")

    cfg = _Config.from_env()
    msg = _build_message(
        cfg,
        to=to.strip(),
        subject=subject,
        body=body or "",
        html=html,
        reply_to=reply_to.strip() if reply_to else None,
        from_name_override=from_name.strip() if from_name else None,
    )

    # We always do STARTTLS, never plain. Implicit-TLS-on-465 is also
    # supported by major relays but we standardize on submission/STARTTLS
    # because it's what smtp-relay.gmail.com prefers and what every
    # major Workspace tenant ends up at by default.
    context = ssl.create_default_context()

    try:
        with smtplib.SMTP(cfg.host, cfg.port, timeout=timeout_seconds) as conn:
            conn.ehlo()
            conn.starttls(context=context)
            conn.ehlo()
            conn.login(cfg.username, cfg.password)
            conn.send_message(msg, from_addr=cfg.mail_from, to_addrs=[msg["To"]])
    except (smtplib.SMTPException, OSError, socket.timeout) as e:
        raise SMTPSendError(f"send to {to!r} failed: {e}") from e


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="send_email.py",
        description="Send a single email via the configured SMTP relay. "
                    "Reads SMTP_* env vars (varlock-resolved from "
                    "op://Honeybot/SMTP/*).",
    )
    p.add_argument("--to", required=True, help="recipient address")
    p.add_argument("--subject", required=True, help="subject line")
    p.add_argument(
        "--body",
        help="plain-text body. If omitted, read body from stdin.",
    )
    p.add_argument(
        "--html",
        help="optional HTML body. If supplied, message becomes "
             "multipart/alternative with --body as the text fallback.",
    )
    p.add_argument(
        "--reply-to",
        help="optional Reply-To header; envelope From always stays "
             "$SMTP_MAIL_FROM.",
    )
    p.add_argument(
        "--from-name",
        help="override SMTP_MAIL_FROM_NAME for this single send.",
    )
    return p


def _main(argv: Optional[list[str]] = None) -> int:
    args = _build_parser().parse_args(argv)
    body = args.body if args.body is not None else sys.stdin.read()

    try:
        send(
            to=args.to,
            subject=args.subject,
            body=body,
            html=args.html,
            reply_to=args.reply_to,
            from_name=args.from_name,
        )
    except SMTPNotConfigured as e:
        print(f"send_email: {e}", file=sys.stderr)
        return 4
    except SMTPSendError as e:
        print(f"send_email: {e}", file=sys.stderr)
        return 5
    except ValueError as e:
        print(f"send_email: usage: {e}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
