"""Environment-driven configuration.

Secrets (token map, Slack bot token, honeybot api_server key) arrive via
.env.runtime (emitted by the secrets-init compose service from 1Password)
and are read here from the process env. Non-secret tuning (ports,
timeouts, model, upstream URL) is set in docker-compose.yml's
`environment:` block.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass

log = logging.getLogger("voice_relay.config")


@dataclass(frozen=True)
class Config:
    port: int
    fast_ack_seconds: float
    agent_timeout_seconds: float
    honeybot_api_url: str
    honeybot_api_key: str
    honeybot_model: str
    slack_bot_token: str
    token_map: dict  # bearer token -> Slack UID
    ack_message: str

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            port=int(os.environ.get("VOICE_RELAY_PORT", "8080")),
            # How long the voice client is willing to wait for a real answer
            # before we hand back the "I'll DM you" ack. Keep under the
            # assistant's own patience (~5s for Siri).
            fast_ack_seconds=float(os.environ.get("VOICE_FAST_ACK_SECONDS", "3.5")),
            # Hard cap on a single agent run, after which we give up and DM
            # a failure notice rather than leak a hung task forever.
            agent_timeout_seconds=float(os.environ.get("VOICE_AGENT_TIMEOUT_SECONDS", "300")),
            honeybot_api_url=os.environ.get("HONEYBOT_API_URL", "http://honeybot:8642/v1").rstrip("/"),
            honeybot_api_key=os.environ.get("HONEYBOT_API_KEY", ""),
            honeybot_model=os.environ.get("HONEYBOT_MODEL", "honeybot"),
            slack_bot_token=os.environ.get("SLACK_BOT_TOKEN", ""),
            token_map=_parse_token_map(os.environ.get("VOICE_TOKEN_MAP", "")),
            ack_message=os.environ.get(
                "VOICE_ACK_MESSAGE",
                "On it — I'll message you in Slack when it's done.",
            ),
        )


def _parse_token_map(raw: str) -> dict:
    """Parse VOICE_TOKEN_MAP (a compact JSON object) into token->UID.

    Empty or malformed → empty map. An empty map means the relay is
    fail-closed: every request 401s until a real map is populated in
    op://Honeybot/Voice/token_map. That's the correct resting state for
    a public endpoint that triggers real actions.
    """
    raw = (raw or "").strip()
    if not raw:
        log.warning("VOICE_TOKEN_MAP is empty — all voice requests will 401")
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as e:
        log.error("VOICE_TOKEN_MAP is not valid JSON (%s) — treating as empty", e)
        return {}
    if not isinstance(parsed, dict):
        log.error("VOICE_TOKEN_MAP must be a JSON object — treating as empty")
        return {}
    # Normalize: string keys/values only.
    return {str(k).strip(): str(v).strip() for k, v in parsed.items() if k and v}
