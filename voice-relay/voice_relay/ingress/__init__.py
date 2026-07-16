"""Ingress plugin layer.

Each ingress is a transport binding for one class of voice client. It
parses that client's inbound shape into a VoiceRequest, calls
core.handle(), and shapes the VoiceReply back. Adding a new client is a
new module here + one line in ENABLED_INGRESSES — the core never changes.
"""

from voice_relay.ingress.mcp import McpIngress
from voice_relay.ingress.siri import SiriIngress

# The active ingress set. Adding a client = a new module here + one entry.
#   SiriIngress — HTTP POST /v1/voice/ask (Siri Shortcuts, any HTTP client)
#   McpIngress  — MCP /mcp (Claude voice, ChatGPT voice; degrades to no-op
#                 if the mcp SDK isn't installed)
ENABLED_INGRESSES = [
    SiriIngress(),
    McpIngress(),
]
