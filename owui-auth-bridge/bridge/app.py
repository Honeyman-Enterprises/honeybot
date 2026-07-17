"""aiohttp reverse proxy: verify identity → mint → inject session key → forward.

Per request:
  1. Inbound gate: require the api_server bearer (only Open WebUI, which has
     it, should reach the bridge — it also listens honeynet-only). Constant-
     time compare.
  2. STRIP any client-supplied X-Hermes-Session-Key — a caller must never be
     able to assert their own session identity.
  3. If X-OpenWebUI-User-Email is present, round-trip verify (verify.py). On
     success mint a trusted session and set X-Hermes-Session-Key =
     {interface}:{slack_uid}. On failure, forward WITHOUT a session key
     (stays unverified → falls back to OTP). Fail closed, never mint for an
     unconfirmed identity.
  4. Transparently proxy method/path/body/headers to the api_server and
     stream the response back (SSE-safe).
"""

from __future__ import annotations

import asyncio
import hmac
import logging

from aiohttp import ClientSession, ClientTimeout, web

from bridge import lookups
from bridge import mint as mint_mod
from bridge.config import Config
from bridge.verify import Verifier

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("owui-auth-bridge")

# Hop-by-hop headers (RFC 7230 §6.1) must not be forwarded.
_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length",
}


def build_app(config: Config | None = None) -> web.Application:
    config = config or Config.from_env()
    verifier = Verifier(
        allowed_domains=config.allowed_domains,
        slack_lookup=lookups.slack_lookup_factory(config.slack_bot_token),
        owui_lookup=lookups.owui_lookup_factory(config.owui_api_url, config.owui_api_key),
        require_owui=config.require_owui,
    )
    app = web.Application()
    app["config"] = config
    app["verifier"] = verifier
    app.router.add_get("/healthz", _health)
    app.router.add_route("*", "/{tail:.*}", _proxy)

    owui = "on" if config.owui_api_url and config.owui_api_key else "off"
    log.info(
        "bridge ready: upstream=%s domains=%s owui_roundtrip=%s require_owui=%s",
        config.upstream_url, sorted(config.allowed_domains), owui, config.require_owui,
    )
    return app


async def _health(_request):
    return web.json_response({"ok": True})


async def _proxy(request: web.Request) -> web.StreamResponse:
    config: Config = request.app["config"]
    verifier: Verifier = request.app["verifier"]

    if not _bearer_ok(request.headers.get("Authorization", ""), config.api_server_key):
        return web.json_response({"error": "unauthorized"}, status=401)

    session_key = ""
    email = request.headers.get("X-OpenWebUI-User-Email", "")
    uid_claim = request.headers.get("X-OpenWebUI-User-Id", "")

    if email:
        result = await asyncio.to_thread(
            verifier.verify, claimed_email=email, claimed_user_id=uid_claim
        )
        if result.ok and result.identity:
            candidate = f"{config.interface}:{result.identity.slack_uid}"
            try:
                await asyncio.to_thread(mint_mod.mint, result.identity, candidate, config.interface)
                session_key = candidate
                log.info("verified %s -> %s", result.identity.email, result.identity.slack_uid)
            except Exception:
                # Fail closed: if we can't persist the trusted session, do
                # NOT assert identity downstream.
                log.exception("mint failed; forwarding unverified")
        else:
            log.warning("identity NOT verified (%s): %s", email, result.reason)

    return await _forward(request, config, session_key)


async def _forward(request: web.Request, config: Config, session_key: str) -> web.StreamResponse:
    # Build upstream headers: drop hop-by-hop, and ALWAYS drop any inbound
    # X-Hermes-Session-Key so a client can't assert its own identity — we
    # set it ourselves only when verification succeeded.
    headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in _HOP and k.lower() != "x-hermes-session-key"
    }
    if session_key:
        headers["X-Hermes-Session-Key"] = session_key

    body = await request.read()
    upstream = config.upstream_url + request.raw_path
    timeout = ClientTimeout(total=None, sock_connect=15, sock_read=config.read_timeout)

    async with ClientSession(timeout=timeout, auto_decompress=False) as sess:
        async with sess.request(
            request.method, upstream, headers=headers, data=body, allow_redirects=False,
        ) as up:
            resp_headers = {
                k: v for k, v in up.headers.items()
                if k.lower() not in _HOP and k.lower() != "content-encoding"
            }
            resp = web.StreamResponse(status=up.status, headers=resp_headers)
            await resp.prepare(request)
            async for chunk in up.content.iter_any():
                await resp.write(chunk)
            await resp.write_eof()
            return resp


def _bearer_ok(authorization: str, expected: str) -> bool:
    if not expected:
        return False  # no key configured => reject (fail closed)
    presented = authorization[7:].strip() if authorization.lower().startswith("bearer ") else authorization.strip()
    return hmac.compare_digest(presented, expected)
