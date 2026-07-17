"""Self-hosted MCP OAuth authorization server, Google upstream.

Turns the voice-relay into an OAuth 2.1 authorization server that MCP
clients (Claude/ChatGPT) register with via DCR + PKCE, delegating login to
Google, then issues tokens carrying the requester's Slack UID. See
docs/voice-relay-oauth.md.

SECURITY: this is an auth server. It must pass a security review and a live
handshake against a real client before it's trusted. It stays dormant until
a Google client is configured (see config).
"""
