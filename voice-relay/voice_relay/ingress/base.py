"""Ingress protocol — the contract every voice front-end binding implements."""

from __future__ import annotations

from typing import Protocol

from voice_relay.core import Core


class Ingress(Protocol):
    """One transport binding (a set of HTTP routes, or MCP tools).

    mount() attaches the binding to the running app: parse the client's
    request into a VoiceRequest, `await core.handle(req)`, and shape the
    VoiceReply into the client's response format. Auth (bearer token
    extraction) happens here; identity *resolution* happens in the core.
    """

    name: str

    def mount(self, app, core: Core) -> None: ...


def bearer(authorization: str) -> str:
    """Extract a bearer token from an Authorization header value."""
    value = (authorization or "").strip()
    if value.lower().startswith("bearer "):
        return value[7:].strip()
    return value
