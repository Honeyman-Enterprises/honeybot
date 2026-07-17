"""Transport-agnostic request/reply types.

Every ingress (Siri HTTP, MCP, …) normalizes its client-specific payload
into a VoiceRequest and shapes the core's VoiceReply back into whatever
that client expects. The core never sees a transport-specific type.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True)
class VoiceRequest:
    """A normalized spoken command from any voice front-end."""

    text: str
    """The command, already voice→text'd by the client."""

    token: str
    """Per-user bearer token; resolves to a Slack UID (see identity.py)."""

    client: str
    """Which ingress produced this: 'siri' | 'claude-voice' | …"""

    request_id: str
    """Idempotency key. Client-supplied when available, else relay-generated."""

    slack_uid: str = ""
    """Pre-resolved Slack UID. Set by the OAuth path (identity comes from the
    validated access token); when empty the core resolves `token` via the
    TokenStore (the static-bearer path)."""


@dataclass(frozen=True)
class VoiceReply:
    """What the relay hands back to the voice client synchronously."""

    speech: str
    """What the client speaks NOW."""

    status: Literal["answered", "accepted"]
    """answered = fast path (speech is the real result);
    accepted = slow path (speech is the ack; result arrives via Slack DM)."""

    request_id: str
