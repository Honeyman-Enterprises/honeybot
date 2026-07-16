#!/usr/bin/env python3
"""voice-token.py — self-service voice-relay token management.

Mints / rotates / revokes the per-user bearer token that a voice client
(Claude voice, ChatGPT voice, Siri Shortcut) presents to the voice-relay
so honeybot knows who's asking and where to DM the result.

Identity is resolved exactly like creds.sh:
  1. --user UID          (admin/debug override)
  2. $HONEYBOT_SLACK_USER (CLI/local-dev)
  3. per-session sidecar  (Slack gateway path)
  4. OTP-verified session (non-Slack: Open WebUI, API — via verify_session)
No identity → refuse. This is the identity model; there is no default user.

1Password is the source of truth:
  op://Honeybot/Voice/token_map   JSON { token: slack_uid }  (durable)
  op://Honeybot/Voice/admin_key   bearer for the relay's /admin/tokens
After any change we push the full map to the relay so a fresh token works
without a restart. op access uses the container's OP_SERVICE_ACCOUNT_TOKEN.

Actions:
  generate   mint a new token for the caller (replaces any existing one)
  rotate     alias for generate
  revoke     remove the caller's token(s)
  show       reveal the caller's current token (if any)

Usage:
  voice-token.py <generate|rotate|revoke|show> [--user UID]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

VAULT = os.environ.get("HONEYBOT_VAULT", "Honeybot")
TOKEN_MAP_REF = f"op://{VAULT}/Voice/token_map"
ADMIN_KEY_REF = f"op://{VAULT}/Voice/admin_key"
RELAY_URL = os.environ.get("VOICE_RELAY_URL", "http://voice-relay:8080").rstrip("/")
_SLACK_UID_RE = re.compile(r"^[UW][A-Z0-9]{8,}$")
_LIB = Path(__file__).resolve().parents[2] / "_lib"


def die(msg: str, code: int = 1) -> None:
    print(f"voice-token: {msg}", file=sys.stderr)
    sys.exit(code)


# --------------------------------------------------------------------------
# Identity — mirror creds.sh precedence.
# --------------------------------------------------------------------------
def resolve_uid(explicit: str | None) -> str:
    if explicit:
        uid = explicit.strip()
    elif os.environ.get("HONEYBOT_SLACK_USER"):
        uid = os.environ["HONEYBOT_SLACK_USER"].strip()
    else:
        uid = _from_sidecar() or _from_otp()

    if not uid:
        die(
            "no Slack user ID for this session. On Slack this is automatic; "
            "on Open WebUI / API you must verify your identity first "
            "(the OTP flow). No default user.",
            code=2,
        )
    if not _SLACK_UID_RE.match(uid):
        die(f"'{uid}' does not look like a Slack user ID; refusing.", code=2)
    return uid


def _from_sidecar() -> str:
    key = os.environ.get("HERMES_SESSION_KEY", "")
    if not key:
        return ""
    safe = key.replace(":", "_").replace("/", "_")
    sidecar = Path(f"/tmp/honeybot-identity/{safe}/HONEYBOT_SLACK_USER")
    if sidecar.is_file():
        return sidecar.read_text(encoding="utf-8").strip()
    return ""


def _from_otp() -> str:
    """Ask the OTP gate who this non-Slack session belongs to (exit 0 → uid)."""
    key = os.environ.get("HERMES_SESSION_KEY", "")
    if not key:
        return ""
    try:
        out = subprocess.run(
            [sys.executable, str(_LIB / "verify_session.py"), "--session-key", key],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if out.returncode == 0 and out.stdout.strip():
        try:
            return (json.loads(out.stdout).get("slack_uid") or "").strip()
        except json.JSONDecodeError:
            return ""
    # Not verified — surface the OTP instruction to the agent verbatim.
    if out.returncode == 4:
        die(
            "identity not verified for this interface. Run the OTP flow "
            "(otp-identity-verification skill) first, then retry.",
            code=4,
        )
    return ""


# --------------------------------------------------------------------------
# 1Password + relay.
# --------------------------------------------------------------------------
def _op_read(ref: str) -> str:
    try:
        out = subprocess.run(
            ["op", "read", ref], capture_output=True, text=True, timeout=20
        )
    except (OSError, subprocess.SubprocessError) as e:
        die(f"op read failed: {e}", code=3)
    return out.stdout.strip() if out.returncode == 0 else ""


def load_map() -> dict:
    raw = _op_read(TOKEN_MAP_REF)
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        die("op://Honeybot/Voice/token_map is not valid JSON; fix it in 1Password.", code=3)
    return {str(k): str(v) for k, v in data.items()} if isinstance(data, dict) else {}


def save_map(token_map: dict) -> None:
    blob = json.dumps(token_map, separators=(",", ":"))  # compact, single-line
    try:
        res = subprocess.run(
            ["op", "item", "edit", "Voice", "--vault", VAULT, f"token_map={blob}"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as e:
        die(f"op item edit failed: {e}", code=3)
    if res.returncode != 0:
        die(f"op item edit failed: {res.stderr.strip()}", code=3)


def push_to_relay(token_map: dict) -> str:
    """PUT the full map to the relay so new tokens go live immediately.

    Best-effort: op is already saved (durable). If the relay is unreachable
    we warn rather than fail — the token still activates on the next
    compose up (VOICE_TOKEN_MAP is re-seeded from op).
    """
    admin_key = _op_read(ADMIN_KEY_REF)
    if not admin_key:
        return "note: no admin_key in 1Password — token saved but not pushed live."
    body = json.dumps({"tokens": token_map}).encode()
    req = urllib.request.Request(
        f"{RELAY_URL}/admin/tokens", data=body, method="PUT",
        headers={"Authorization": f"Bearer {admin_key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            json.load(resp)
        return "live: pushed to the relay."
    except (urllib.error.URLError, OSError) as e:
        return f"note: saved to 1Password, but live push to the relay failed ({e}). It'll activate on the next deploy."


# --------------------------------------------------------------------------
# Actions.
# --------------------------------------------------------------------------
def _new_token() -> str:
    return "tok_" + secrets.token_urlsafe(24)


def do_generate(uid: str) -> None:
    token_map = load_map()
    # One active token per user: drop any existing tokens for this uid.
    token_map = {t: u for t, u in token_map.items() if u != uid}
    token = _new_token()
    token_map[token] = uid
    save_map(token_map)
    status = push_to_relay(token_map)
    print(
        f"✅ Voice token for {uid}:\n\n    {token}\n\n"
        "Put this in your voice client's connector/bearer auth "
        "(Claude/ChatGPT MCP connector, or a Siri Shortcut header). "
        "It replaces any previous token you had.\n"
        f"({status})"
    )


def do_revoke(uid: str) -> None:
    token_map = load_map()
    remaining = {t: u for t, u in token_map.items() if u != uid}
    if len(remaining) == len(token_map):
        print(f"No voice token was set for {uid} — nothing to revoke.")
        return
    save_map(remaining)
    status = push_to_relay(remaining)
    print(f"✅ Revoked the voice token for {uid}. It no longer works.\n({status})")


def do_show(uid: str) -> None:
    token_map = load_map()
    mine = [t for t, u in token_map.items() if u == uid]
    if not mine:
        print(f"No voice token set for {uid}. Say 'generate my voice token' to make one.")
        return
    print(f"Your current voice token:\n\n    {mine[0]}\n")


def main() -> int:
    p = argparse.ArgumentParser(prog="voice-token.py")
    p.add_argument("action", choices=["generate", "rotate", "revoke", "show"])
    p.add_argument("--user", default="")
    args = p.parse_args()

    uid = resolve_uid(args.user or None)
    if args.action in ("generate", "rotate"):
        do_generate(uid)
    elif args.action == "revoke":
        do_revoke(uid)
    else:
        do_show(uid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
