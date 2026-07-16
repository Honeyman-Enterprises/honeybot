"""Ingress plugin layer.

Each ingress is a transport binding for one class of voice client. It
parses that client's inbound shape into a VoiceRequest, calls
core.handle(), and shapes the VoiceReply back. Adding a new client is a
new module here + one line in ENABLED_INGRESSES — the core never changes.
"""

from voice_relay.ingress.siri import SiriIngress

# The active ingress set. Phase 2 adds McpIngress here for Claude/ChatGPT
# voice; Phase 4 can add a generic webhook for Alexa/Home Assistant.
ENABLED_INGRESSES = [
    SiriIngress(),
]
