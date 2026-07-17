"""
honeybot-identity hook — propagate the requesting Slack user's ID into a
per-session sidecar file that skill subprocesses can read.

Why this exists
---------------
The Hermes gateway already knows who sent every inbound message — it has
to, in order to enforce SLACK_ALLOWED_USERS. It exposes that ID inside the
agent process via gateway.session_context.HERMES_SESSION_USER_ID, which is
a ContextVar (task-local, concurrency-safe across asyncio tasks).

But ContextVars don't propagate to child processes. When the agent shells
out to a skill (e.g. ./skills/gmail/bin/gmail.sh), the subprocess inherits
os.environ, not the gateway's contextvars. So the skill can't see the
user ID, and creds.sh — which is the one place that's allowed to read
op://Honeybot/{Service}-{UID}/... — has to fail closed.

Setting os.environ["HONEYBOT_SLACK_USER"] from this hook would be a race
condition under concurrent messages from different users. Instead we
write the ID to a per-session file keyed on the session_key, which
*is* exported into subprocess env (Hermes sets os.environ["HERMES_SESSION_KEY"]
in run_sync just before tool execution). creds.sh reads that file, gets
the user ID, builds the vault path, and proceeds.

Reading the session_key in this hook
------------------------------------
We read it via gateway.session_context.get_session_env, NOT os.environ.
Why: at agent:start emit time (gateway/run.py:4676), the gateway has
already set the HERMES_SESSION_KEY ContextVar (gateway/run.py:4226 via
_set_session_env), but it has NOT yet set os.environ["HERMES_SESSION_KEY"]
— that happens later, inside run_sync (gateway/run.py:9732), after the
hook has fired. Reading os.environ here therefore raced and produced the
"agent:start fired without HERMES_SESSION_KEY in env" warning, which in
turn caused the sidecar to never be written and every per-user skill to
fail closed.

get_session_env() reads the contextvar first and falls back to os.environ
for CLI/cron paths that don't go through the gateway, so it's safe in all
contexts.

Lifecycle
---------
- agent:start  → ensure the sidecar file exists with the current user_id
- session:end  → delete the sidecar file (defensive cleanup; not required
                 for correctness because the file is keyed on session_key
                 and gets overwritten per-message anyway)

Storage
-------
/tmp/honeybot-identity/{session_key_safe}/HONEYBOT_SLACK_USER

session_key contains colons (e.g. agent:main:slack:dm:D0AU...:ts), which
are valid in Linux paths but ugly. We replace them with `_` for filesystem
sanity. The mapping is one-way and stable per session, which is all
creds.sh needs.

The file is mode 0600, owned by the runtime UID. /tmp is process-private
in the container (no host bind-mount), so it's not visible outside.
"""

from __future__ import annotations

import logging
import os
import re
import sys
from pathlib import Path

# Make otp_auth (skills/_lib) importable so non-Slack sessions can resolve
# their Slack UID from a verified/trusted session — e.g. one minted by the
# owui-auth-bridge after a round-trip-verified Google login. Path:
# ~/.hermes/hooks/honeybot-identity/handler.py -> ~/.hermes/skills/_lib.
_SKILLS_LIB = Path(__file__).resolve().parents[2] / "skills" / "_lib"
if _SKILLS_LIB.is_dir():
    sys.path.insert(0, str(_SKILLS_LIB))

# Prefer the gateway's contextvar-aware session accessor. At agent:start
# emit time, the gateway has already populated the HERMES_SESSION_KEY
# ContextVar but has NOT yet written it to os.environ — that happens
# later in run_sync. See module docstring for the full ordering.
#
# Fall back to os.environ when the gateway module isn't importable
# (e.g. CLI tests, hook unit tests, cron jobs that load this module
# directly). The fallback preserves the legacy behavior so we never get
# *worse* than before.
try:
    from gateway.session_context import get_session_env  # type: ignore
except ImportError:  # pragma: no cover - exercised only in standalone tests
    def get_session_env(name: str, default: str = "") -> str:
        return os.environ.get(name, default)

logger = logging.getLogger("hooks.honeybot-identity")

IDENTITY_ROOT = Path("/tmp/honeybot-identity")
USER_FILE_NAME = "HONEYBOT_SLACK_USER"

# Slack user IDs are [UW][A-Z0-9]{8,}. We mirror the same regex that
# skills/_lib/creds.sh uses so we never write garbage that would later
# get rejected downstream — fail at the producer, not the consumer.
_SLACK_UID_RE = re.compile(r"^[UW][A-Z0-9]{8,}$")


def _safe_session_dir(session_key: str) -> Path:
    """Map a Hermes session_key to a filesystem-safe per-session directory."""
    # session_key format: "agent:main:slack:dm:CHANNEL_ID:THREAD_TS"
    # Replace ":" with "_" so the path is one segment under IDENTITY_ROOT.
    safe = session_key.replace(":", "_").replace("/", "_")
    return IDENTITY_ROOT / safe


def _write_user_id(session_key: str, user_id: str) -> None:
    """Atomically write the user ID to the per-session sidecar file."""
    session_dir = _safe_session_dir(session_key)
    session_dir.mkdir(parents=True, exist_ok=True)
    # Tighten perms on the directory itself (best-effort).
    try:
        os.chmod(session_dir, 0o700)
    except OSError:
        pass

    target = session_dir / USER_FILE_NAME
    tmp = target.with_suffix(".tmp")
    tmp.write_text(user_id, encoding="utf-8")
    os.chmod(tmp, 0o600)
    # Atomic on POSIX — replaces target without a torn read window.
    os.replace(tmp, target)


def _delete_session(session_key: str) -> None:
    """Remove the per-session sidecar (best-effort)."""
    session_dir = _safe_session_dir(session_key)
    target = session_dir / USER_FILE_NAME
    try:
        target.unlink(missing_ok=True)
    except OSError as e:
        logger.debug("could not unlink %s: %s", target, e)
    try:
        session_dir.rmdir()
    except OSError:
        # Non-empty or already gone — fine either way.
        pass


def _verified_uid(session_key: str) -> str:
    """Resolve a Slack UID from a verified/trusted session (non-Slack only).

    Returns "" for Slack sessions (they have their own identity path), when
    otp_auth isn't importable, or when there's no valid verified session.
    The UID is only used if it passes the Slack-UID regex at the call site.
    """
    interface = session_key.split(":", 1)[0] if session_key else ""
    if not interface or interface == "slack":
        return ""
    try:
        from otp_auth import check_session  # skills/_lib, added to sys.path above
    except ImportError:
        return ""
    try:
        session = check_session(session_key, interface=interface)
    except Exception:  # never let identity resolution abort the pipeline
        return ""
    return (session.slack_uid or "").strip() if session else ""


async def handle(event_type: str, context: dict) -> None:
    """Gateway hook entrypoint.

    For agent:start, persist the requesting user's Slack ID. For
    session:end, clean up the sidecar.

    Errors are logged and swallowed — this hook MUST NOT block the agent
    pipeline. If the sidecar can't be written, downstream skills will
    simply fail closed at creds.sh, which is the existing behavior.
    """
    try:
        if event_type == "agent:start":
            session_key = get_session_env("HERMES_SESSION_KEY", "")
            user_id = (context.get("user_id") or "").strip()

            if not session_key:
                # If we're here despite reading via get_session_env, neither
                # the contextvar nor os.environ had a value. That's a real
                # bug in the gateway, not the race we used to hit.
                logger.warning(
                    "agent:start fired without HERMES_SESSION_KEY in "
                    "contextvar or env; skipping sidecar write"
                )
                return

            if not _SLACK_UID_RE.match(user_id):
                # Slack sets a Slack UID in context. Non-Slack interfaces
                # (Open WebUI, API) don't — but if a trusted session was
                # minted for this session_key (the owui-auth-bridge does
                # this after a round-trip-verified Google login), resolve
                # the Slack UID from that verified session so creds.sh can
                # use the normal sidecar path (no --user, no OTP prompt).
                verified = _verified_uid(session_key)
                if verified:
                    user_id = verified
                else:
                    # Genuinely non-Slack + unverified: nothing to write.
                    logger.debug(
                        "user_id %r is not a Slack UID and no verified "
                        "session for %s; skipping",
                        user_id, session_key,
                    )
                    return

            _write_user_id(session_key, user_id)
            logger.debug(
                "wrote sidecar for session=%s user=%s", session_key, user_id
            )

        elif event_type == "session:end":
            session_key = get_session_env("HERMES_SESSION_KEY", "")
            if not session_key:
                return
            _delete_session(session_key)
            logger.debug("cleared sidecar for session=%s", session_key)

    except Exception as e:
        # Never let a hook failure abort message processing.
        logger.error("honeybot-identity hook failed on %s: %s", event_type, e)
