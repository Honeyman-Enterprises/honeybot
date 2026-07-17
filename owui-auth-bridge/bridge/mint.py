"""Mint a trusted session in honeybot's shared auth store.

Reuses honeybot's own otp_auth.establish_trusted_session (COPY'd into the
image at /app/_lib/otp_auth.py) so the trust logic lives in ONE place. The
store is a volume shared with honeybot; HONEYBOT_AUTH_DIR must point both
containers at the same directory.
"""

from __future__ import annotations

import sys
from pathlib import Path

# otp_auth reads HONEYBOT_AUTH_DIR at import time — the compose env sets it
# to the shared /auth volume before the process starts.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "_lib"))

import otp_auth  # noqa: E402

from bridge.verify import Identity  # noqa: E402


def mint(identity: Identity, session_key: str, interface: str = "openwebui"):
    """Write a verified session for the (already round-trip-verified) identity."""
    return otp_auth.establish_trusted_session(
        email=identity.email,
        slack_uid=identity.slack_uid,
        session_key=session_key,
        interface=interface,
    )
