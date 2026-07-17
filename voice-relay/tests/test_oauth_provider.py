"""OAuth authorization-server provider tests — the security logic.

Requires the `mcp` SDK (the provider builds on its models). Run in a venv
that has mcp installed:
    python3 tests/test_oauth_provider.py

Google's token exchange is monkeypatched (no network); PKCE/redirect
validation is the SDK's job and out of scope here — these tests cover the
decisions the provider owns.
"""

import asyncio
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from mcp.shared.auth import OAuthClientInformationFull
from mcp.server.auth.provider import AuthorizationParams, RefreshToken
from pydantic import AnyUrl

from voice_relay.oauth import google, provider as provmod
from voice_relay.oauth.provider import HoneybotOAuthProvider
from voice_relay.oauth.store import Store

PUBLIC = "https://voice.honeybot.honeymanenterprises.com"
CLIENT_REDIRECT = "https://claude.ai/api/mcp/auth_callback"
ERIC = "U09NS7DSK8U"


def _provider(store=None, uid_map=None):
    uid_map = uid_map if uid_map is not None else {"eric@honeymanenterprises.com": ERIC}
    return HoneybotOAuthProvider(
        public_url=PUBLIC,
        google_client_id="gid", google_client_secret="gsecret",
        allowed_domains={"honeymanenterprises.com"},
        slack_uid_resolver=lambda e: uid_map.get(e.lower(), ""),
        store=store or Store(),
    )


def _client():
    return OAuthClientInformationFull(client_id="mcp-client-1",
                                      redirect_uris=[AnyUrl(CLIENT_REDIRECT)])


def _params():
    return AuthorizationParams(
        state="client-state-xyz", scopes=[], code_challenge="chal123",
        redirect_uri=AnyUrl(CLIENT_REDIRECT), redirect_uri_provided_explicitly=True,
    )


def _patch_google(email="eric@honeymanenterprises.com"):
    google.exchange_code_for_email = lambda **kw: email


async def _authorize_and_callback(p, email="eric@honeymanenterprises.com"):
    """Drive authorize() -> capture state -> complete_google_callback()."""
    url = await p.authorize(_client(), _params())
    assert url.startswith("https://accounts.google.com/"), url
    state = dict([kv.split("=", 1) for kv in url.split("?", 1)[1].split("&")])["state"]
    _patch_google(email)
    return await p.complete_google_callback("google-code", state)


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f": {detail}" if not cond else ""))
    if not cond:
        FAILURES.append(name)


FAILURES = []


def test_register_and_get_client():
    async def run():
        p = _provider()
        await p.register_client(_client())
        got = await p.get_client("mcp-client-1")
        check("register_get_client", got is not None and got.client_id == "mcp-client-1", str(got))
        check("get_unknown_client_none", await p.get_client("nope") is None)
    asyncio.run(run())


def test_authorize_redirects_to_google_and_stores_state():
    async def run():
        p = _provider()
        url = await p.authorize(_client(), _params())
        check("authorize_google_url", "accounts.google.com" in url and "state=" in url, url)
    asyncio.run(run())


def test_full_happy_path_to_token():
    async def run():
        p = _provider()
        redirect = await _authorize_and_callback(p)
        check("callback_redirects_to_client", redirect.startswith(CLIENT_REDIRECT), redirect)
        check("callback_carries_client_state", "state=client-state-xyz" in redirect, redirect)
        code = dict([kv.split("=", 1) for kv in redirect.split("?", 1)[1].split("&")])["code"]
        # load + exchange the code
        loaded = await p.load_authorization_code(_client(), code)
        check("code_loads_with_uid", loaded is not None and loaded.slack_uid == ERIC, str(loaded))
        tok = await p.exchange_authorization_code(_client(), loaded)
        check("token_issued", tok.access_token and tok.refresh_token, str(tok))
        # code is one-time
        check("code_consumed", await p.load_authorization_code(_client(), code) is None)
        # access token validates and carries identity
        at = await p.load_access_token(tok.access_token)
        check("access_token_valid_uid", at is not None and at.slack_uid == ERIC, str(at))
    asyncio.run(run())


def test_callback_rejects_bad_domain():
    async def run():
        p = _provider(uid_map={"x@evil.com": "UEVIL"})
        raised = ""
        try:
            await _authorize_and_callback(p, email="x@evil.com")
        except Exception as e:
            raised = type(e).__name__
        check("reject_bad_domain", raised == "PermissionError", raised)
    asyncio.run(run())


def test_callback_rejects_unknown_email():
    async def run():
        p = _provider(uid_map={})  # nobody resolves
        raised = ""
        try:
            await _authorize_and_callback(p, email="ghost@honeymanenterprises.com")
        except Exception as e:
            raised = type(e).__name__
        check("reject_no_slack_uid", raised == "PermissionError", raised)
    asyncio.run(run())


def test_callback_rejects_unknown_state():
    async def run():
        p = _provider()
        _patch_google()
        raised = ""
        try:
            await p.complete_google_callback("code", "forged-state")
        except Exception as e:
            raised = type(e).__name__
        check("reject_unknown_state", raised == "ValueError", raised)
    asyncio.run(run())


def test_wrong_client_cannot_load_code():
    async def run():
        p = _provider()
        redirect = await _authorize_and_callback(p)
        code = dict([kv.split("=", 1) for kv in redirect.split("?", 1)[1].split("&")])["code"]
        other = OAuthClientInformationFull(client_id="attacker", redirect_uris=[AnyUrl(CLIENT_REDIRECT)])
        check("other_client_code_none", await p.load_authorization_code(other, code) is None)
    asyncio.run(run())


def test_refresh_rotates():
    async def run():
        p = _provider()
        redirect = await _authorize_and_callback(p)
        code = dict([kv.split("=", 1) for kv in redirect.split("?", 1)[1].split("&")])["code"]
        loaded = await p.load_authorization_code(_client(), code)
        tok = await p.exchange_authorization_code(_client(), loaded)
        rt = await p.load_refresh_token(_client(), tok.refresh_token)
        check("refresh_loads", rt is not None and rt.client_id == "mcp-client-1", str(rt))
        tok2 = await p.exchange_refresh_token(_client(), rt, [])
        check("refresh_issues_new", tok2.access_token != tok.access_token, "same token!")
        # old refresh is rotated out
        check("old_refresh_revoked", await p.load_refresh_token(_client(), tok.refresh_token) is None)
    asyncio.run(run())


def test_store_persists_across_reload():
    async def run():
        path = os.path.join(tempfile.mkdtemp(), "oauth.json")
        s1 = Store(path)
        p1 = _provider(store=s1)
        await p1.register_client(_client())
        redirect = await _authorize_and_callback(p1)
        code = dict([kv.split("=", 1) for kv in redirect.split("?", 1)[1].split("&")])["code"]
        # NB: codes/pending are in-memory by design, so re-issue a token to persist.
        loaded = await p1.load_authorization_code(_client(), code)
        tok = await p1.exchange_authorization_code(_client(), loaded)
        # New Store from the same file: client + access token survive.
        s2 = Store(path)
        p2 = _provider(store=s2)
        check("client_persisted", await p2.get_client("mcp-client-1") is not None)
        at = await p2.load_access_token(tok.access_token)
        check("token_persisted", at is not None and at.slack_uid == ERIC, str(at))
    asyncio.run(run())


def _all():
    return [v for k, v in sorted(globals().items()) if k.startswith("test_")]


if __name__ == "__main__":
    for fn in _all():
        try:
            fn()
        except Exception as e:  # noqa: BLE001
            import traceback; traceback.print_exc()
            FAILURES.append(fn.__name__)
    total_checks = "see PASS/FAIL above"
    print(f"\n{'ALL GREEN' if not FAILURES else f'FAILURES: {FAILURES}'}")
    sys.exit(1 if FAILURES else 0)
