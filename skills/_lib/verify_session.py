#!/usr/bin/env python3
"""
verify_session.py — credential access gate for Honeybot.

This script is the enforcement point for OTP identity verification.
Any script or skill that accesses per-user credentials MUST call this
first (or source the check from creds.sh, which calls this).

Usage:
  verify_session.py [--session-key KEY] [--interface IF] [--email EMAIL]

  If --session-key is omitted, reads $HERMES_SESSION_KEY from the environment.

Output (stdout):
  On success: JSON with verified identity info
    {"status": "verified", "email": "...", "slack_uid": "...", "expires_at": "..."}

  On failure: JSON with status and instruction
    {"status": "not_verified", "message": "..."}

Exit codes:
  0   session is verified — proceed with credential access
  4   session NOT verified — must complete OTP first
  2   usage error (missing session key)
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# Add auth dir to path so we can import otp_auth
auth_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(auth_dir))

from otp_auth import check_session


def main() -> int:
    import argparse

    p = argparse.ArgumentParser(prog="verify_session.py")
    p.add_argument("--session-key", default="")
    p.add_argument("--interface", default="")
    p.add_argument("--email", default="")
    args = p.parse_args()

    session_key = args.session_key or os.environ.get("HERMES_SESSION_KEY", "")

    if not session_key:
        print(json.dumps({
            "status": "error",
            "message": "No session key available. Set HERMES_SESSION_KEY or pass --session-key.",
        }))
        return 2

    session = check_session(session_key, interface=args.interface, email=args.email)

    if session:
        print(json.dumps({
            "status": "verified",
            "email": session.email,
            "slack_uid": session.slack_uid,
            "interface": session.interface,
            "verified_at": datetime.fromtimestamp(
                session.verified_at, tz=timezone.utc
            ).isoformat(),
            "expires_at": datetime.fromtimestamp(
                session.expires_at, tz=timezone.utc
            ).isoformat(),
        }))
        return 0
    else:
        print(json.dumps({
            "status": "not_verified",
            "message": (
                "This session has not been identity-verified. "
                "Before accessing credentials, the user must complete "
                "OTP verification: send a code to their email, "
                "then enter it here."
            ),
        }))
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
