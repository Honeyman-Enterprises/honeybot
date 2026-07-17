"""Round-trip verification tests — the security heart of the bridge.

Stdlib only:
    python3 tests/test_verify.py
    pytest tests/test_verify.py

Every test asserts the decision an attacker or a mis-forward would hit.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from bridge.verify import Verifier

DOMAINS = {"honeymanenterprises.com"}
ERIC = "U09NS7DSK8U"
MICHELLE = "U09NS7H5J5S"


def _slack_db(*users):
    # users: dicts keyed by email
    by_email = {u["profile"]["email"].lower(): u for u in users}

    def lookup(email):
        return by_email.get(email.lower())

    return lookup


def _user(uid, email, deleted=False, is_bot=False):
    return {
        "id": uid,
        "deleted": deleted,
        "is_bot": is_bot,
        "profile": {"email": email},
    }


def _verifier(slack_lookup, owui_lookup=None, require_owui=False):
    return Verifier(
        allowed_domains=DOMAINS,
        slack_lookup=slack_lookup,
        owui_lookup=owui_lookup,
        require_owui=require_owui,
    )


def test_happy_path_resolves_uid_from_slack_not_header():
    slack = _slack_db(_user(ERIC, "eric@honeymanenterprises.com"))
    v = _verifier(slack)
    # Header claims a DIFFERENT (bogus) user_id — must be ignored; uid comes
    # from Slack keyed on the email.
    r = v.verify(claimed_email="eric@honeymanenterprises.com", claimed_user_id="owui-abc")
    assert r.ok, r.reason
    assert r.identity.slack_uid == ERIC, r.identity
    assert r.identity.email == "eric@honeymanenterprises.com"


def test_reject_email_not_in_slack():
    slack = _slack_db(_user(ERIC, "eric@honeymanenterprises.com"))
    r = _verifier(slack).verify(
        claimed_email="ghost@honeymanenterprises.com", claimed_user_id="x"
    )
    assert not r.ok and "no user" in r.reason.lower(), r.reason


def test_reject_wrong_domain():
    slack = _slack_db(_user(ERIC, "eric@evil.com"))
    r = _verifier(slack).verify(claimed_email="eric@evil.com", claimed_user_id="x")
    assert not r.ok and "domain not allowed" in r.reason.lower(), r.reason


def test_reject_deleted_account():
    slack = _slack_db(_user(ERIC, "eric@honeymanenterprises.com", deleted=True))
    r = _verifier(slack).verify(
        claimed_email="eric@honeymanenterprises.com", claimed_user_id="x"
    )
    assert not r.ok and "deleted" in r.reason.lower(), r.reason


def test_reject_bot_account():
    slack = _slack_db(_user(ERIC, "eric@honeymanenterprises.com", is_bot=True))
    r = _verifier(slack).verify(
        claimed_email="eric@honeymanenterprises.com", claimed_user_id="x"
    )
    assert not r.ok and "bot" in r.reason.lower(), r.reason


def test_reject_slack_email_mismatch():
    # Slack lookup returns a user whose canonical email differs from the
    # claim (shouldn't happen via lookupByEmail, but defend anyway).
    def slack(email):
        return _user(ERIC, "someoneelse@honeymanenterprises.com")

    r = _verifier(slack).verify(
        claimed_email="eric@honeymanenterprises.com", claimed_user_id="x"
    )
    assert not r.ok and "mismatch" in r.reason.lower(), r.reason


def test_owui_roundtrip_confirms_pair():
    slack = _slack_db(_user(ERIC, "eric@honeymanenterprises.com"))
    owui = lambda uid: {"id": uid, "email": "eric@honeymanenterprises.com"} if uid == "owui-eric" else None
    v = _verifier(slack, owui_lookup=owui)
    r = v.verify(claimed_email="eric@honeymanenterprises.com", claimed_user_id="owui-eric")
    assert r.ok, r.reason


def test_owui_roundtrip_rejects_pair_mismatch():
    # Attacker forwards Eric's email but Michelle's OWUI user_id (or an
    # account whose OWUI email is different) → the OWUI round-trip catches it.
    slack = _slack_db(_user(ERIC, "eric@honeymanenterprises.com"))
    owui = lambda uid: {"id": uid, "email": "michelle@honeymanenterprises.com"}
    r = _verifier(slack, owui_lookup=owui).verify(
        claimed_email="eric@honeymanenterprises.com", claimed_user_id="owui-michelle"
    )
    assert not r.ok and "open webui email" in r.reason.lower(), r.reason


def test_owui_roundtrip_rejects_unknown_user_id():
    slack = _slack_db(_user(ERIC, "eric@honeymanenterprises.com"))
    owui = lambda uid: None
    r = _verifier(slack, owui_lookup=owui).verify(
        claimed_email="eric@honeymanenterprises.com", claimed_user_id="nope"
    )
    assert not r.ok and "no such user" in r.reason.lower(), r.reason


def test_require_owui_rejects_when_unconfigured():
    slack = _slack_db(_user(ERIC, "eric@honeymanenterprises.com"))
    r = _verifier(slack, owui_lookup=None, require_owui=True).verify(
        claimed_email="eric@honeymanenterprises.com", claimed_user_id="x"
    )
    assert not r.ok and "required but not configured" in r.reason.lower(), r.reason


def test_empty_domain_list_denies_all():
    slack = _slack_db(_user(ERIC, "eric@honeymanenterprises.com"))
    v = Verifier(allowed_domains=set(), slack_lookup=slack)
    r = v.verify(claimed_email="eric@honeymanenterprises.com", claimed_user_id="x")
    assert not r.ok, "empty allow-list must fail closed"


def test_blank_email_rejected():
    r = _verifier(_slack_db()).verify(claimed_email="", claimed_user_id="x")
    assert not r.ok and "claimed email" in r.reason.lower(), r.reason


def _all():
    return [v for k, v in sorted(globals().items()) if k.startswith("test_")]


if __name__ == "__main__":
    fails = 0
    for fn in _all():
        try:
            fn()
            print(f"PASS  {fn.__name__}")
        except AssertionError as e:
            fails += 1
            print(f"FAIL  {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            fails += 1
            print(f"ERROR {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(_all()) - fails}/{len(_all())} passed")
    sys.exit(1 if fails else 0)
