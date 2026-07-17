#!/usr/bin/env python3
"""
otp_auth.py — OTP-based identity verification for Honeybot.

This module is the single source of truth for the OTP identity flow:
  1. Generate a 6-digit code for an email address
  2. Send it via the existing SMTP infrastructure (send_email.py)
  3. Verify the code the user types back
  4. Track verified sessions so credential-accessing tools can gate on it

Storage: two JSON files under ~/.hermes/auth/
  - pending_otps.json   — codes waiting to be verified
  - verified_sessions.json — sessions that passed OTP

The gate: verify_session() checks if the current session has a valid
verified identity. If not, the caller must initiate the OTP flow.

CLI usage:
  otp_auth.py generate --email USER@EXAMPLE.COM --session-key KEY [--interface slack]
  otp_auth.py verify   --code 123456 --session-key KEY
  otp_auth.py check    --session-key KEY
  otp_auth.py revoke   --session-key KEY

Library usage:
  from auth.otp_auth import generate_otp, verify_otp, check_session, get_verified_email

Exit codes (CLI):
  0   success
  1   verification failed (wrong/expired code)
  2   usage error
  3   SMTP send failure
  4   session not verified (check only)
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import secrets
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

AUTH_DIR = Path(os.environ.get("HONEYBOT_AUTH_DIR", os.path.expanduser("~/.hermes/auth")))
PENDING_FILE = AUTH_DIR / "pending_otps.json"
VERIFIED_FILE = AUTH_DIR / "verified_sessions.json"

OTP_LENGTH = 6
OTP_TTL_SECONDS = 5 * 60       # 5 minutes to enter the code
SESSION_TTL_SECONDS = 30 * 24 * 60 * 60  # 30 days — sliding window, refreshed on each use
MAX_ATTEMPTS = 5                # per OTP, after which it's burned

_SLACK_UID_RE = re.compile(r"^[UW][A-Z0-9]{8,}$")

# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------

@dataclass
class PendingOTP:
    code_hash: str          # SHA-256 of the code (never store plaintext)
    email: str
    session_key: str
    interface: str          # slack, openwebui, discord, etc.
    claimed_uid: str        # Slack UID the user claims to be
    created_at: float       # time.time()
    expires_at: float
    attempts: int = 0

    @property
    def is_expired(self) -> bool:
        return time.time() > self.expires_at


@dataclass
class VerifiedSession:
    email: str
    slack_uid: str
    session_key: str
    interface: str
    verified_at: float
    expires_at: float
    last_used_at: float = 0.0  # updated on every successful check (sliding window)

    @property
    def is_expired(self) -> bool:
        return time.time() > self.expires_at


# ---------------------------------------------------------------------------
# Persistence helpers (atomic JSON read/write with file locking)
# ---------------------------------------------------------------------------

def _ensure_dir():
    AUTH_DIR.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(AUTH_DIR, 0o700)
    except OSError:
        pass


def _read_json(path: Path) -> dict:
    """Read a JSON file, returning {} if missing or corrupt."""
    try:
        with open(path, "r") as f:
            fcntl.flock(f, fcntl.LOCK_SH)
            data = json.load(f)
            fcntl.flock(f, fcntl.LOCK_UN)
            return data
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _write_json(path: Path, data: dict) -> None:
    """Atomically write a JSON file with exclusive lock."""
    _ensure_dir()
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        json.dump(data, f, indent=2, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
        fcntl.flock(f, fcntl.LOCK_UN)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _hash_code(code: str) -> str:
    """SHA-256 hash a code. We never store plaintext OTPs."""
    return hashlib.sha256(code.encode()).hexdigest()


# ---------------------------------------------------------------------------
# Pending OTP management
# ---------------------------------------------------------------------------

def _load_pending() -> dict[str, dict]:
    """Load pending OTPs, pruning expired entries."""
    raw = _read_json(PENDING_FILE)
    now = time.time()
    # Prune expired
    cleaned = {k: v for k, v in raw.items() if v.get("expires_at", 0) > now}
    if len(cleaned) != len(raw):
        _write_json(PENDING_FILE, cleaned)
    return cleaned


def _save_pending(data: dict[str, dict]) -> None:
    _write_json(PENDING_FILE, data)


# ---------------------------------------------------------------------------
# Verified session management
# ---------------------------------------------------------------------------

def _load_verified() -> dict[str, dict]:
    """Load verified sessions, pruning expired entries."""
    raw = _read_json(VERIFIED_FILE)
    now = time.time()
    cleaned = {k: v for k, v in raw.items() if v.get("expires_at", 0) > now}
    if len(cleaned) != len(raw):
        _write_json(VERIFIED_FILE, cleaned)
    return cleaned


def _save_verified(data: dict[str, dict]) -> None:
    _write_json(VERIFIED_FILE, data)


# ---------------------------------------------------------------------------
# Session key normalization
#
# Different interfaces generate different session keys for the same user.
# For OTP verification, we key on a normalized form that groups by
# interface + user identity rather than per-thread:
#   - Slack: "slack:{channel_id}" (strips thread TS so all threads in a DM share auth)
#   - OpenWebUI / API: "api:{user_email_or_id}" (if known) or the raw key
#   - Default: the raw session key
#
# The full session_key is still stored in the record for audit, but the
# dict key is the normalized version.
# ---------------------------------------------------------------------------

def _normalize_session_key(session_key: str, interface: str = "", email: str = "") -> str:
    """Produce a stable lookup key from a session key.

    For Slack sessions (format: agent:main:slack:dm:CHANNEL:TS),
    we strip the thread timestamp so that verification persists across
    threads in the same DM channel.

    For non-Slack interfaces (OpenWebUI, API), we key on
    interface + email so that verification persists across sessions
    from the same authenticated user on the same interface.
    """
    parts = session_key.split(":")
    # Slack DM: agent:main:slack:dm:CHANNEL:TS → use channel only
    if len(parts) >= 5 and parts[2] == "slack":
        return f"slack:{parts[4]}"
    # Non-Slack: use interface + email if available
    if interface and email:
        return f"{interface}:{email}"
    # Fallback: use the raw key
    return session_key


# ---------------------------------------------------------------------------
# Core API
# ---------------------------------------------------------------------------

def generate_otp(
    *,
    email: str,
    session_key: str,
    interface: str = "unknown",
    claimed_uid: str = "",
    send: bool = True,
) -> str:
    """Generate and optionally send an OTP code.

    Returns the plaintext code (for the caller to use in testing or
    if sending is handled externally). In production, set send=True
    and the code goes via email; the return value should be discarded.
    """
    if not email or "@" not in email:
        raise ValueError(f"Invalid email: {email!r}")
    if not session_key:
        raise ValueError("session_key is required")

    code = "".join(str(secrets.randbelow(10)) for _ in range(OTP_LENGTH))
    now = time.time()

    norm_key = _normalize_session_key(session_key, interface, email)

    pending = _load_pending()
    pending[norm_key] = asdict(PendingOTP(
        code_hash=_hash_code(code),
        email=email,
        session_key=session_key,
        interface=interface,
        claimed_uid=claimed_uid,
        created_at=now,
        expires_at=now + OTP_TTL_SECONDS,
        attempts=0,
    ))
    _save_pending(pending)

    if send:
        _send_otp_email(email, code)

    return code


def verify_otp(*, code: str, session_key: str, interface: str = "", email: str = "") -> VerifiedSession:
    """Verify a code. Returns VerifiedSession on success, raises on failure."""
    if not code or not session_key:
        raise ValueError("code and session_key are required")

    norm_key = _normalize_session_key(session_key, interface, email)
    pending = _load_pending()

    record = pending.get(norm_key)
    if not record:
        raise VerificationError("No pending OTP for this session. Request a new code.")

    if record.get("expires_at", 0) < time.time():
        del pending[norm_key]
        _save_pending(pending)
        raise VerificationError("OTP expired. Request a new code.")

    record["attempts"] = record.get("attempts", 0) + 1
    if record["attempts"] > MAX_ATTEMPTS:
        del pending[norm_key]
        _save_pending(pending)
        raise VerificationError(
            f"Too many failed attempts ({MAX_ATTEMPTS}). Request a new code."
        )

    if _hash_code(code) != record["code_hash"]:
        pending[norm_key] = record
        _save_pending(pending)
        remaining = MAX_ATTEMPTS - record["attempts"]
        raise VerificationError(
            f"Incorrect code. {remaining} attempt(s) remaining."
        )

    # Success — remove pending, create verified session
    del pending[norm_key]
    _save_pending(pending)

    now = time.time()
    verified = VerifiedSession(
        email=record["email"],
        slack_uid=record.get("claimed_uid", ""),
        session_key=record["session_key"],
        interface=record.get("interface", "unknown"),
        verified_at=now,
        expires_at=now + SESSION_TTL_SECONDS,
    )

    sessions = _load_verified()
    sessions[norm_key] = asdict(verified)
    _save_verified(sessions)

    return verified


def slack_uid_for_email(email: str, *, bot_token: str = "") -> str:
    """Resolve a Slack user ID from an email via users.lookupByEmail.

    Uses SLACK_BOT_TOKEN (the bot needs the users:read.email scope). Returns
    the UID, or "" if not found / on any error — callers must fail closed on
    the empty case.
    """
    import urllib.error
    import urllib.parse
    import urllib.request

    token = bot_token or os.environ.get("SLACK_BOT_TOKEN", "")
    if not token or not email:
        return ""
    url = "https://slack.com/api/users.lookupByEmail?" + urllib.parse.urlencode({"email": email})
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.load(resp)
    except (urllib.error.URLError, OSError, json.JSONDecodeError):
        return ""
    if data.get("ok") and isinstance(data.get("user"), dict):
        return data["user"].get("id", "") or ""
    return ""


def establish_trusted_session(
    *,
    email: str,
    slack_uid: str,
    session_key: str,
    interface: str = "openwebui",
) -> VerifiedSession:
    """Mint a verified session WITHOUT an OTP code.

    For callers that have already proven the user's identity by a factor at
    least as strong as email-OTP — e.g. a domain-restricted Google OAuth
    login in Open WebUI, where Google itself asserts the verified email.
    Same end state as a successful ``verify_otp``, minus the emailed code.

    SECURITY — read before calling:
      The OTP gate exists precisely because a chat message is NOT proof of
      identity. This function is a trusted-issuer bypass of that gate, so it
      MUST only be invoked from a path where (email, slack_uid) was
      established out-of-band by a trusted authenticator (OAuth), NEVER from
      anything the user typed or from an unauthenticated request. Wiring it
      to the wrong input re-opens the exact cross-user credential-read hole
      the gate closes. See docs/openwebui-google-identity.md.
    """
    if not email or "@" not in email:
        raise ValueError(f"Invalid email: {email!r}")
    if not _SLACK_UID_RE.match(slack_uid or ""):
        raise ValueError(f"slack_uid {slack_uid!r} is not a Slack user ID")
    if not session_key:
        raise ValueError("session_key is required")

    now = time.time()
    verified = VerifiedSession(
        email=email,
        slack_uid=slack_uid,
        session_key=session_key,
        interface=interface,
        verified_at=now,
        expires_at=now + SESSION_TTL_SECONDS,
        last_used_at=now,
    )
    # Key it the way the gate looks it up. creds.sh → verify_session.py
    # calls check_session(session_key, interface) with NO email, so the
    # lookup normalizes to the raw session_key (for non-Slack). Storing
    # under the email-keyed variant here would make the gate never find it.
    norm_key = _normalize_session_key(session_key, interface)
    sessions = _load_verified()
    sessions[norm_key] = asdict(verified)
    _save_verified(sessions)
    return verified


def check_session(session_key: str, interface: str = "", email: str = "") -> Optional[VerifiedSession]:
    """Check if a session is verified. Returns VerifiedSession or None."""
    if not session_key:
        return None

    norm_key = _normalize_session_key(session_key, interface, email)
    sessions = _load_verified()
    record = sessions.get(norm_key)

    if not record:
        return None

    now = time.time()
    if record.get("expires_at", 0) < now:
        del sessions[norm_key]
        _save_verified(sessions)
        return None

    # Sliding window: refresh expiry on every successful check
    new_expires = now + SESSION_TTL_SECONDS
    if record.get("expires_at", 0) != new_expires:
        record["expires_at"] = new_expires
        record["last_used_at"] = now
        sessions[norm_key] = record
        _save_verified(sessions)

    return VerifiedSession(**{
        k: record[k] for k in VerifiedSession.__dataclass_fields__
        if k in record
    })


def get_verified_email(session_key: str, interface: str = "", email: str = "") -> Optional[str]:
    """Convenience: get the verified email for a session, or None."""
    session = check_session(session_key, interface, email)
    return session.email if session else None


def get_verified_uid(session_key: str, interface: str = "", email: str = "") -> Optional[str]:
    """Convenience: get the verified Slack UID for a session, or None."""
    session = check_session(session_key, interface, email)
    return session.slack_uid if session else None


def revoke_session(session_key: str, interface: str = "", email: str = "") -> bool:
    """Revoke a verified session. Returns True if it existed."""
    norm_key = _normalize_session_key(session_key, interface, email)
    sessions = _load_verified()
    if norm_key in sessions:
        del sessions[norm_key]
        _save_verified(sessions)
        return True
    return False


# ---------------------------------------------------------------------------
# Email sending
# ---------------------------------------------------------------------------

def _send_otp_email(email: str, code: str) -> None:
    """Send the OTP code via the shared SMTP infrastructure."""
    # Import send_email from the skills lib
    lib_dir = Path(os.path.expanduser("~/.hermes/skills/_lib"))
    if lib_dir.exists():
        sys.path.insert(0, str(lib_dir))

    try:
        from send_email import send, SMTPNotConfigured, SMTPSendError
    except ImportError:
        raise RuntimeError(
            "Cannot import send_email from skills/_lib/. "
            "Ensure ~/.hermes/skills/_lib/send_email.py exists."
        )

    subject = f"Your Honeybot verification code: {code}"
    body = (
        f"Your verification code is: {code}\n\n"
        f"This code expires in {OTP_TTL_SECONDS // 60} minutes.\n\n"
        f"If you didn't request this, you can safely ignore this email.\n"
    )
    html = (
        f'<div style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; '
        f'max-width: 480px; margin: 0 auto; padding: 40px 20px;">'
        f'<h2 style="color: #1a1a1a; margin-bottom: 8px;">Honeybot Verification</h2>'
        f'<p style="color: #666; margin-bottom: 24px;">Enter this code to verify your identity:</p>'
        f'<div style="background: #f5f5f5; border-radius: 8px; padding: 24px; '
        f'text-align: center; margin-bottom: 24px;">'
        f'<span style="font-size: 36px; font-weight: 700; letter-spacing: 8px; '
        f'color: #1a1a1a; font-family: monospace;">{code}</span></div>'
        f'<p style="color: #999; font-size: 13px;">'
        f'This code expires in {OTP_TTL_SECONDS // 60} minutes. '
        f'If you didn\'t request this, ignore this email.</p></div>'
    )

    try:
        send(
            to=email,
            subject=subject,
            body=body,
            html=html,
            from_name="Honeybot Identity Verification",
        )
    except SMTPNotConfigured as e:
        raise RuntimeError(f"SMTP not configured: {e}") from e
    except SMTPSendError as e:
        raise RuntimeError(f"Failed to send OTP email: {e}") from e


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------

class VerificationError(Exception):
    """OTP verification failed (wrong code, expired, too many attempts)."""
    pass


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="otp_auth.py",
        description="OTP identity verification for Honeybot.",
    )
    sub = p.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="Generate and send an OTP")
    gen.add_argument("--email", required=True)
    gen.add_argument("--session-key", required=True)
    gen.add_argument("--interface", default="unknown")
    gen.add_argument("--claimed-uid", default="")
    gen.add_argument("--no-send", action="store_true",
                     help="Don't send email (testing)")

    ver = sub.add_parser("verify", help="Verify an OTP code")
    ver.add_argument("--code", required=True)
    ver.add_argument("--session-key", required=True)
    ver.add_argument("--interface", default="")
    ver.add_argument("--email", default="")

    chk = sub.add_parser("check", help="Check if session is verified")
    chk.add_argument("--session-key", required=True)
    chk.add_argument("--interface", default="")
    chk.add_argument("--email", default="")

    rev = sub.add_parser("revoke", help="Revoke a verified session")
    rev.add_argument("--session-key", required=True)
    rev.add_argument("--interface", default="")
    rev.add_argument("--email", default="")

    # trust — mint a verified session from an already-proven identity (no
    # OTP). ONLY for trusted callers (e.g. the Google-OAuth bridge). See the
    # security note on establish_trusted_session().
    tru = sub.add_parser("trust", help="Mint a verified session from a proven identity (no OTP)")
    tru.add_argument("--email", required=True)
    tru.add_argument("--session-key", required=True)
    tru.add_argument("--interface", default="openwebui")
    tru.add_argument("--uid", default="",
                     help="Slack UID; if omitted, resolved from --email via Slack")

    return p


def _main(argv: Optional[list[str]] = None) -> int:
    args = _build_parser().parse_args(argv)

    try:
        if args.command == "generate":
            code = generate_otp(
                email=args.email,
                session_key=args.session_key,
                interface=args.interface,
                claimed_uid=args.claimed_uid,
                send=not args.no_send,
            )
            if args.no_send:
                print(f"Code (not sent): {code}")
            else:
                print(f"OTP sent to {args.email}")
            return 0

        elif args.command == "verify":
            session = verify_otp(
                code=args.code,
                session_key=args.session_key,
                interface=args.interface,
                email=args.email,
            )
            print(json.dumps({
                "status": "verified",
                "email": session.email,
                "slack_uid": session.slack_uid,
                "expires_at": datetime.fromtimestamp(
                    session.expires_at, tz=timezone.utc
                ).isoformat(),
            }, indent=2))
            return 0

        elif args.command == "check":
            session = check_session(
                args.session_key,
                interface=args.interface,
                email=args.email,
            )
            if session:
                print(json.dumps({
                    "status": "verified",
                    "email": session.email,
                    "slack_uid": session.slack_uid,
                    "verified_at": datetime.fromtimestamp(
                        session.verified_at, tz=timezone.utc
                    ).isoformat(),
                    "expires_at": datetime.fromtimestamp(
                        session.expires_at, tz=timezone.utc
                    ).isoformat(),
                }, indent=2))
                return 0
            else:
                print(json.dumps({"status": "not_verified"}))
                return 4

        elif args.command == "revoke":
            revoked = revoke_session(
                args.session_key,
                interface=args.interface,
                email=args.email,
            )
            print("Revoked" if revoked else "No session to revoke")
            return 0

        elif args.command == "trust":
            uid = args.uid or slack_uid_for_email(args.email)
            if not uid:
                print(json.dumps({
                    "status": "failed",
                    "error": f"could not resolve a Slack UID for {args.email} "
                             "(pass --uid, or check the bot's users:read.email scope)",
                }))
                return 1
            session = establish_trusted_session(
                email=args.email,
                slack_uid=uid,
                session_key=args.session_key,
                interface=args.interface,
            )
            print(json.dumps({
                "status": "verified",
                "email": session.email,
                "slack_uid": session.slack_uid,
                "expires_at": datetime.fromtimestamp(
                    session.expires_at, tz=timezone.utc
                ).isoformat(),
            }, indent=2))
            return 0

    except VerificationError as e:
        print(json.dumps({"status": "failed", "error": str(e)}))
        return 1
    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 3
    except ValueError as e:
        print(f"Usage error: {e}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
