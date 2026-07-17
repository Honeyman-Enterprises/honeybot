"""MCP ingress — Claude / ChatGPT voice.

Two modes, chosen by config:

- **OAuth** (a Google client is configured): the relay is a self-hosted
  OAuth authorization server (voice_relay.oauth) that federates login to
  Google. Identity comes from the validated access token via
  ``get_access_token()`` — no header parsing, no static token.

- **Static bearer** (default / dormant OAuth): the connector presents a
  voice token; identity resolves via the TokenStore.

`build_mcp_app()` returns the MCP ASGI app to be mounted at the ROOT of the
voice subdomain (the OAuth discovery + endpoints must live at root — see
docs/voice-relay-oauth.md). Returns None if the mcp SDK isn't importable or
construction fails — the relay's HTTP/Siri path never depends on MCP.

NB: no ``from __future__ import annotations`` — FastMCP's @tool() introspects
real annotation objects; PEP 563 strings crash it (fixed once already).
"""

import asyncio
import logging
import uuid

from voice_relay.core import Core
from voice_relay.identity import UnknownToken
from voice_relay.types import VoiceRequest

log = logging.getLogger("voice_relay.ingress.mcp")


def build_mcp_app(core: Core, config):
    """Build the MCP ASGI app (root-mounted), or None if MCP is unavailable."""
    try:
        from mcp.server.fastmcp import FastMCP
        from mcp.server.fastmcp.server import Context
    except ImportError:
        log.warning("mcp SDK not installed; MCP ingress disabled.")
        return None

    try:
        if config.oauth_enabled:
            app = _build_oauth(core, config, FastMCP, Context)
            log.info("MCP ingress: OAuth mode (Google upstream) at root")
            return app
        app = _build_bearer(core, config, FastMCP, Context)
        log.info("MCP ingress: static-bearer mode")
        return app
    except Exception:
        log.exception("MCP app failed to build; disabling MCP. Relay stays up.")
        return None


async def _run(core: Core, config, command: str, *, slack_uid: str = "", token: str = "") -> str:
    """Shared: build a VoiceRequest and hand back the spoken reply."""
    req = VoiceRequest(
        text=(command or "").strip(),
        token=token,
        slack_uid=slack_uid,
        client="mcp",
        request_id=f"mcp-{uuid.uuid4().hex[:12]}",
    )
    try:
        reply = await core.handle(req)
    except UnknownToken:
        return (
            "This connector isn't authorized. Generate a voice token in "
            "honeybot (DM it 'generate my voice token') and put it in the "
            "connector's auth settings."
        )
    return reply.speech


# ---------------------------------------------------------------------------
# OAuth mode
# ---------------------------------------------------------------------------
def _build_oauth(core: Core, config, FastMCP, Context):
    from mcp.server.auth.middleware.auth_context import get_access_token
    from mcp.server.auth.settings import AuthSettings, ClientRegistrationOptions
    from pydantic import AnyHttpUrl
    from starlette.responses import PlainTextResponse

    from voice_relay.oauth import slack
    from voice_relay.oauth.provider import HoneybotOAuthProvider
    from voice_relay.oauth.store import Store

    provider = HoneybotOAuthProvider(
        public_url=config.public_url,
        google_client_id=config.oauth_google_client_id,
        google_client_secret=config.oauth_google_client_secret,
        allowed_domains=config.oauth_allowed_domains,
        slack_uid_resolver=slack.resolver(config.slack_bot_token),
        store=Store(config.oauth_store_path),
    )
    mcp = FastMCP(
        "honeybot",
        auth_server_provider=provider,
        auth=AuthSettings(
            issuer_url=AnyHttpUrl(config.public_url),
            client_registration_options=ClientRegistrationOptions(enabled=True),
            required_scopes=[],
        ),
    )

    @mcp.tool()
    async def ask_honeybot(command: str) -> str:
        """Send a command to honeybot and return its response.

        If honeybot can answer quickly it replies inline; otherwise it
        acknowledges and follows up with the result in your Slack DM.
        """
        token = get_access_token()
        uid = getattr(token, "slack_uid", "") if token else ""
        if not uid:
            return "Your session isn't identity-verified. Sign in again."
        return await _run(core, config, command, slack_uid=uid)

    @mcp.custom_route("/oauth/callback", methods=["GET"])
    async def google_callback(request):
        code = request.query_params.get("code", "")
        state = request.query_params.get("state", "")
        err = request.query_params.get("error", "")
        if err or not code or not state:
            return PlainTextResponse(
                f"Sign-in failed: {err or 'missing code/state'}", status_code=400
            )
        try:
            redirect = await provider.complete_google_callback(code, state)
        except PermissionError as e:
            log.warning("oauth callback denied: %s", e)
            return PlainTextResponse(
                "Sign-in denied: your Google account isn't allowed here.",
                status_code=403,
            )
        except Exception as e:  # noqa: BLE001
            log.exception("oauth callback error")
            return PlainTextResponse(f"Sign-in error: {e}", status_code=400)
        # 302 back to the MCP client's redirect_uri with our code.
        return PlainTextResponse(
            "", status_code=302, headers={"Location": redirect}
        )

    return mcp.streamable_http_app()


# ---------------------------------------------------------------------------
# Static-bearer mode (default when OAuth is dormant)
# ---------------------------------------------------------------------------
def _build_bearer(core: Core, config, FastMCP, Context):
    mcp = FastMCP("honeybot")

    @mcp.tool()
    async def ask_honeybot(command: str, ctx: Context) -> str:
        """Send a command to honeybot and return its response."""
        return await _run(core, config, command, token=_bearer_from_ctx(ctx))

    return mcp.streamable_http_app()


def _bearer_from_ctx(ctx) -> str:
    """Best-effort bearer extraction from the MCP request (bearer mode)."""
    try:
        auth = ctx.request_context.request.headers.get("authorization", "")
    except AttributeError:
        return ""
    value = auth.strip()
    return value[7:].strip() if value.lower().startswith("bearer ") else value
