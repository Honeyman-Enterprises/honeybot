"""MCP ingress — Claude voice / ChatGPT voice via a remote MCP connector.

Exposes one MCP tool, ``ask_honeybot(command)``, over the Streamable-HTTP
transport at /mcp. MCP-native clients (Claude's custom connectors, ChatGPT
connectors) add the connector by URL and speak MCP; the tool call funnels
into the SAME core as the Siri HTTP ingress, so the fast-ack / async-DM
behavior is identical.

Auth: the per-user voice token is presented as a bearer on the connector's
HTTP requests. We read it from the request's Authorization header and
resolve it to a Slack UID via the core's token store (fail-closed).

NB: this path needs live verification against a real Claude/ChatGPT
connector — the MCP handshake + how each client passes the bearer can't be
exercised from unit tests. The tool logic itself (token → core.handle) is
covered; the transport wiring is best-effort until smoke-tested end to end.
"""

# NB: deliberately NO `from __future__ import annotations` here. FastMCP's
# @tool() introspects the tool function's parameter annotations with
# issubclass() to find the Context arg; PEP 563 string annotations make that
# raise `TypeError: issubclass() arg 1 must be a class` and crash mount().
# Keep annotations as real objects in this module.

import logging
import uuid

from voice_relay.core import Core
from voice_relay.identity import UnknownToken
from voice_relay.types import VoiceRequest

log = logging.getLogger("voice_relay.ingress.mcp")


class McpIngress:
    name = "mcp"

    def mount(self, app, core: Core) -> None:
        try:
            from mcp.server.fastmcp import FastMCP
            from mcp.server.fastmcp.server import Context
        except ImportError:
            log.warning(
                "mcp SDK not installed; MCP ingress disabled. "
                "Add `mcp` to requirements.txt to enable Claude/ChatGPT voice."
            )
            return

        # Everything below is wrapped: a failure here (tool registration,
        # transport wiring, SDK API drift) must DISABLE MCP, never crash the
        # whole relay. The HTTP/Siri path and the core stay up regardless.
        try:
            mcp = FastMCP("honeybot")

            @mcp.tool()
            async def ask_honeybot(command: str, ctx: Context) -> str:
                """Send a command to honeybot and return its response.

                If honeybot can answer quickly it replies inline; otherwise
                it acknowledges and follows up with the result in the
                requester's Slack DM.
                """
                token = _bearer_from_ctx(ctx)
                req = VoiceRequest(
                    text=(command or "").strip(),
                    token=token,
                    client=self.name,
                    request_id=f"mcp-{uuid.uuid4().hex[:12]}",
                )
                try:
                    reply = await core.handle(req)
                except UnknownToken:
                    return (
                        "This connector isn't authorized. Generate a voice "
                        "token in honeybot (DM it 'generate my voice token') "
                        "and put it in this connector's auth settings."
                    )
                return reply.speech

            # Mount the Streamable-HTTP app under /mcp. nginx forwards the
            # whole voice.* vhost to the relay, so the public URL is
            # https://voice.honeybot.honeymanenterprises.com/mcp
            app.mount("/mcp", mcp.streamable_http_app())
            log.info("MCP ingress mounted at /mcp")
        except Exception:
            log.exception(
                "MCP ingress failed to mount; disabling it. The relay stays "
                "up on the HTTP/Siri path — Claude/ChatGPT voice won't work "
                "until this is fixed."
            )


def _bearer_from_ctx(ctx) -> str:
    """Best-effort extraction of the connector's bearer token.

    The FastMCP request context exposes the underlying ASGI request; the
    Authorization header rides on it. Kept defensive because the exact
    attribute path has moved across mcp SDK versions — verify against the
    pinned version during smoke-test.
    """
    try:
        request = ctx.request_context.request  # starlette Request
        auth = request.headers.get("authorization", "")
    except AttributeError:
        return ""
    value = auth.strip()
    if value.lower().startswith("bearer "):
        return value[7:].strip()
    return value
