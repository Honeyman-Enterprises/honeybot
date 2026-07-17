"""owui-auth-bridge — Open WebUI → honeybot auth bridge.

Sits between Open WebUI and honeybot's api_server. Verifies the signed-in
user's identity by round-trip (Slack, + optional Open WebUI), mints a
trusted OTP session for the verified Slack UID, and injects
X-Hermes-Session-Key so the honeybot side treats the session as
identity-verified — letting a Google login skip the email-OTP dance.

See docs/openwebui-google-identity.md.
"""

__version__ = "0.1.0"
