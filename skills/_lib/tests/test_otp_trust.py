"""Tests for the trusted-session primitives added for the Google-login synergy.

Stdlib only. Runnable two ways:
    python3 skills/_lib/tests/test_otp_trust.py
    pytest skills/_lib/tests/test_otp_trust.py

Uses a temp HONEYBOT_AUTH_DIR so it never touches real session state, and
monkeypatches the Slack HTTP call so no network is required.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

# Point the OTP store at a throwaway dir BEFORE importing otp_auth (it reads
# HONEYBOT_AUTH_DIR at import time).
_TMP = tempfile.mkdtemp(prefix="otp-test-")
os.environ["HONEYBOT_AUTH_DIR"] = _TMP

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import otp_auth  # noqa: E402


def test_establish_trusted_session_is_immediately_verified():
    otp_auth.establish_trusted_session(
        email="eric@honeymanenterprises.com",
        slack_uid="U09NS7DSK8U",
        session_key="openwebui:U09NS7DSK8U",
        interface="openwebui",
    )
    # A subsequent check (as creds.sh would do) finds it verified.
    session = otp_auth.check_session(
        "openwebui:U09NS7DSK8U", interface="openwebui"
    )
    assert session is not None, "trusted session must be checkable"
    assert session.slack_uid == "U09NS7DSK8U", session.slack_uid
    assert session.email == "eric@honeymanenterprises.com"


def test_establish_trusted_session_rejects_non_uid():
    for bad in ("", "not-a-uid", "eric@honeymanenterprises.com"):
        raised = False
        try:
            otp_auth.establish_trusted_session(
                email="eric@honeymanenterprises.com",
                slack_uid=bad,
                session_key="openwebui:x",
            )
        except ValueError:
            raised = True
        assert raised, f"must reject slack_uid={bad!r}"


def test_establish_trusted_session_rejects_bad_email():
    raised = False
    try:
        otp_auth.establish_trusted_session(
            email="not-an-email",
            slack_uid="U09NS7DSK8U",
            session_key="openwebui:U09NS7DSK8U",
        )
    except ValueError:
        raised = True
    assert raised, "must reject a malformed email"


def test_slack_uid_for_email_parses_ok(monkeypatch=None):
    import io
    import json as _json

    class _Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, timeout=0):
        return _Resp(_json.dumps({"ok": True, "user": {"id": "U09NS7DSK8U"}}).encode())

    orig = otp_auth.__dict__.get("urllib", None)
    import urllib.request

    saved = urllib.request.urlopen
    urllib.request.urlopen = fake_urlopen
    try:
        uid = otp_auth.slack_uid_for_email(
            "eric@honeymanenterprises.com", bot_token="xoxb-test"
        )
    finally:
        urllib.request.urlopen = saved
    assert uid == "U09NS7DSK8U", uid


def test_slack_uid_for_email_empty_on_not_found():
    import io
    import json as _json
    import urllib.request

    class _Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, timeout=0):
        return _Resp(_json.dumps({"ok": False, "error": "users_not_found"}).encode())

    saved = urllib.request.urlopen
    urllib.request.urlopen = fake_urlopen
    try:
        uid = otp_auth.slack_uid_for_email("nobody@example.com", bot_token="xoxb-test")
    finally:
        urllib.request.urlopen = saved
    assert uid == "", f"expected empty, got {uid!r}"


def test_slack_uid_for_email_empty_without_token():
    assert otp_auth.slack_uid_for_email("x@y.com", bot_token="") == ""


def _all_tests():
    return [v for k, v in sorted(globals().items()) if k.startswith("test_")]


if __name__ == "__main__":
    failures = 0
    for fn in _all_tests():
        try:
            fn()
            print(f"PASS  {fn.__name__}")
        except AssertionError as e:
            failures += 1
            print(f"FAIL  {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failures += 1
            print(f"ERROR {fn.__name__}: {type(e).__name__}: {e}")
    total = len(_all_tests())
    print(f"\n{total - failures}/{total} passed")
    sys.exit(1 if failures else 0)
