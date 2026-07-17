"""OAuthAuthorizationServerProvider — the authorization server, Google upstream.

Implements the mcp SDK provider interface. The SDK owns the HTTP endpoints
(/authorize, /token, /register, metadata) and PKCE verification; this class
owns the decisions: register clients (DCR), redirect /authorize to Google,
turn Google's callback into our own one-time authorization code carrying the
resolved Slack UID, and issue/validate opaque tokens.

Security properties (for review):
  - `state` binds our Google round-trip to the client's /authorize request;
    it's single-use (pop_pending).
  - The SDK validates the client's redirect_uri (against its DCR record) and
    PKCE before our code is ever exchanged.
  - We refuse to mint a code unless Google says the email is verified, its
    domain is allow-listed, AND it resolves to a Slack UID.
  - Authorization codes are one-time (pop on exchange). Access/refresh
    tokens are opaque and server-validated; refresh rotates.
"""

from __future__ import annotations

import asyncio
import secrets
import time
import urllib.parse

from mcp.server.auth.provider import RefreshToken
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken
from pydantic import AnyUrl

from voice_relay.oauth import google
from voice_relay.oauth.models import HoneybotAccessToken, HoneybotAuthorizationCode
from voice_relay.oauth.store import Store, TokenRecord

ACCESS_TTL = 3600               # 1h access tokens
REFRESH_TTL = 30 * 24 * 3600    # 30d refresh tokens
CODE_TTL = 300                  # 5m authorization codes


class HoneybotOAuthProvider:
    def __init__(
        self,
        *,
        public_url: str,
        google_client_id: str,
        google_client_secret: str,
        allowed_domains,
        slack_uid_resolver,   # callable(email) -> slack_uid | ""
        store: Store,
    ):
        self._public_url = public_url.rstrip("/")
        self._google_redirect = f"{self._public_url}/oauth/callback"
        self._gid = google_client_id
        self._gsecret = google_client_secret
        self._domains = {d.strip().lower() for d in allowed_domains if d.strip()}
        self._resolve_uid = slack_uid_resolver
        self._store = store

    # ---- DCR ---------------------------------------------------------------
    async def get_client(self, client_id: str):
        raw = self._store.get_client(client_id)
        return OAuthClientInformationFull.model_validate(raw) if raw else None

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        self._store.put_client(client_info.client_id, client_info.model_dump(mode="json"))

    # ---- authorize -> Google ----------------------------------------------
    async def authorize(self, client: OAuthClientInformationFull, params) -> str:
        # The SDK has already validated params.redirect_uri against the
        # client's registered redirect_uris. Stash the request under our own
        # single-use state and send the user to Google.
        state = secrets.token_urlsafe(24)
        self._store.put_pending(state, {
            "client_id": client.client_id,
            "redirect_uri": str(params.redirect_uri),
            "redirect_uri_provided_explicitly": params.redirect_uri_provided_explicitly,
            "code_challenge": params.code_challenge,
            "client_state": params.state,
            "scopes": params.scopes or [],
        })
        return google.auth_url(
            client_id=self._gid, redirect_uri=self._google_redirect, state=state
        )

    async def complete_google_callback(self, code: str, state: str) -> str:
        """Handle Google's redirect. Returns the URL to send the client back to.

        Called by the /oauth/callback custom route. Raises on any failure so
        the route can render an error instead of redirecting.
        """
        pending = self._store.pop_pending(state)
        if not pending:
            raise ValueError("unknown or expired authorization state")

        # Google exchange + Slack lookup are blocking urllib — run them off
        # the event loop so a login doesn't stall the relay.
        email = await asyncio.to_thread(
            google.exchange_code_for_email,
            code=code, client_id=self._gid,
            client_secret=self._gsecret, redirect_uri=self._google_redirect,
        )
        domain = email.rsplit("@", 1)[-1]
        if not self._domains or domain not in self._domains:
            raise PermissionError(f"email domain not allowed: {email}")
        uid = await asyncio.to_thread(self._resolve_uid, email)
        if not uid:
            raise PermissionError(f"no Slack user for {email}")

        our_code = secrets.token_urlsafe(24)
        self._store.put_code(our_code, HoneybotAuthorizationCode(
            code=our_code,
            scopes=pending["scopes"],
            expires_at=time.time() + CODE_TTL,
            client_id=pending["client_id"],
            code_challenge=pending["code_challenge"],
            redirect_uri=AnyUrl(pending["redirect_uri"]),
            redirect_uri_provided_explicitly=pending["redirect_uri_provided_explicitly"],
            slack_uid=uid,
            email=email,
        ))
        return _redirect_with_code(
            pending["redirect_uri"], our_code, pending.get("client_state")
        )

    # ---- code + token ------------------------------------------------------
    async def load_authorization_code(self, client, authorization_code: str):
        code = self._store.get_code(authorization_code)
        if not code or code.client_id != client.client_id:
            return None
        if code.expires_at < time.time():
            return None
        return code

    async def exchange_authorization_code(self, client, authorization_code) -> OAuthToken:
        # PKCE + redirect_uri already checked by the SDK. One-time use.
        self._store.pop_code(authorization_code.code)
        return self._issue(
            client.client_id, authorization_code.scopes,
            authorization_code.slack_uid, authorization_code.email,
        )

    async def load_access_token(self, token: str):
        rec = self._store.get_access(token)
        if not rec or (rec.expires_at and rec.expires_at < time.time()):
            return None
        return HoneybotAccessToken(
            token=token, client_id=rec.client_id, scopes=rec.scopes,
            expires_at=rec.expires_at, slack_uid=rec.slack_uid, email=rec.email,
        )

    async def load_refresh_token(self, client, refresh_token: str):
        rec = self._store.get_refresh(refresh_token)
        if not rec or rec.client_id != client.client_id:
            return None
        return RefreshToken(
            token=refresh_token, client_id=rec.client_id,
            scopes=rec.scopes, expires_at=rec.expires_at or None,
        )

    async def exchange_refresh_token(self, client, refresh_token, scopes) -> OAuthToken:
        rec = self._store.get_refresh(refresh_token.token)
        if not rec:
            raise ValueError("unknown refresh token")
        self._store.revoke(refresh_token.token)  # rotate
        return self._issue(client.client_id, scopes or rec.scopes, rec.slack_uid, rec.email)

    async def revoke_token(self, token) -> None:
        self._store.revoke(getattr(token, "token", token))

    def _issue(self, client_id, scopes, slack_uid, email) -> OAuthToken:
        access = secrets.token_urlsafe(32)
        refresh = secrets.token_urlsafe(32)
        now = int(time.time())
        scopes = list(scopes or [])
        self._store.put_access(access, TokenRecord(
            slack_uid=slack_uid, email=email, client_id=client_id,
            scopes=scopes, expires_at=now + ACCESS_TTL, refresh_token=refresh,
        ))
        self._store.put_refresh(refresh, TokenRecord(
            slack_uid=slack_uid, email=email, client_id=client_id,
            scopes=scopes, expires_at=now + REFRESH_TTL,
        ))
        return OAuthToken(
            access_token=access, token_type="Bearer", expires_in=ACCESS_TTL,
            scope=" ".join(scopes) if scopes else None, refresh_token=refresh,
        )


def _redirect_with_code(redirect_uri: str, code: str, client_state) -> str:
    sep = "&" if "?" in redirect_uri else "?"
    q = {"code": code}
    if client_state:
        q["state"] = client_state
    return redirect_uri + sep + urllib.parse.urlencode(q)
