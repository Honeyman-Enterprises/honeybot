"""Environment-driven config. Secrets via .env.runtime; tuning via compose."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    port: int
    upstream_url: str          # honeybot api_server, e.g. http://honeybot:8642
    api_server_key: str        # bearer OWUI presents (= HermesAPI key); required inbound
    slack_bot_token: str       # for users.lookupByEmail (needs users:read.email)
    allowed_domains: set       # e.g. {"honeymanenterprises.com"}
    owui_api_url: str          # optional OWUI round-trip base, e.g. http://openwebui:8080
    owui_api_key: str          # optional OWUI admin API key
    require_owui: bool         # if True, no/failed OWUI round-trip => reject
    interface: str             # session-key prefix, "openwebui"
    read_timeout: float

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            port=int(os.environ.get("BRIDGE_PORT", "8080")),
            upstream_url=os.environ.get("UPSTREAM_URL", "http://honeybot:8642").rstrip("/"),
            api_server_key=os.environ.get("API_SERVER_KEY", ""),
            slack_bot_token=os.environ.get("SLACK_BOT_TOKEN", ""),
            allowed_domains={
                d.strip().lower()
                for d in os.environ.get("OAUTH_ALLOWED_DOMAINS", "honeymanenterprises.com").split(",")
                if d.strip()
            },
            owui_api_url=os.environ.get("OWUI_API_URL", ""),
            owui_api_key=os.environ.get("OWUI_API_KEY", ""),
            require_owui=os.environ.get("BRIDGE_REQUIRE_OWUI", "false").lower() == "true",
            interface=os.environ.get("BRIDGE_INTERFACE", "openwebui"),
            read_timeout=float(os.environ.get("BRIDGE_READ_TIMEOUT", "600")),
        )
