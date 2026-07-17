"""Ingress plugin layer.

Each ingress is a transport binding that adds routes to the relay's FastAPI
app (parse client shape → VoiceRequest → core.handle → shape reply back).

MCP is special: it is NOT in this list because it must be mounted at the
ROOT of the app (its OAuth discovery + endpoints live at root). app.py
builds it via ingress.mcp.build_mcp_app() and mounts it last.
"""

from voice_relay.ingress.siri import SiriIngress

ENABLED_INGRESSES = [
    SiriIngress(),
]
