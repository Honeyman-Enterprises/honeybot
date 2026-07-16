"""honeybot voice-relay — voice assistants → honeybot.

Thin sidecar that lets voice front-ends (Siri, Claude voice, ChatGPT
voice, …) hand a spoken command to honeybot, answer inline when fast,
and DM the requester in Slack when the work outlasts the assistant's
response window. See docs/voice-relay.md for the full design.
"""

__version__ = "0.1.0"
