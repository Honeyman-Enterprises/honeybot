"""FastAPI app factory — wires config → core → ingresses."""

from __future__ import annotations

import logging

from fastapi import FastAPI

from voice_relay.config import Config
from voice_relay.core import Core
from voice_relay.honeybot_client import HoneybotClient
from voice_relay.identity import Identity
from voice_relay.ingress import ENABLED_INGRESSES
from voice_relay.registry import Registry
from voice_relay.slack_client import SlackClient

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("voice_relay")


def build_app(config: Config | None = None) -> FastAPI:
    config = config or Config.from_env()

    registry = Registry()
    core = Core(
        identity=Identity(config.token_map),
        registry=registry,
        honeybot=HoneybotClient(
            config.honeybot_api_url,
            config.honeybot_api_key,
            config.honeybot_model,
            config.agent_timeout_seconds,
        ),
        slack=SlackClient(config.slack_bot_token),
        config=config,
    )

    app = FastAPI(title="honeybot voice-relay", docs_url=None, redoc_url=None)

    @app.get("/healthz")
    async def healthz():
        return {"ok": True, "ingress": [i.name for i in ENABLED_INGRESSES]}

    @app.get("/status")
    async def status():
        # Non-secret debug view of in-flight requests.
        return {"in_flight": registry.snapshot()}

    for ingress in ENABLED_INGRESSES:
        ingress.mount(app, core)
        log.info("mounted ingress: %s", ingress.name)

    log.info(
        "voice-relay ready: %d authorized token(s), fast_ack=%.1fs, upstream=%s",
        len(config.token_map),
        config.fast_ack_seconds,
        config.honeybot_api_url,
    )
    return app
