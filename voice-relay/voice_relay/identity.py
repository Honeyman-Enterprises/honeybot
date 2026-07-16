"""Map a per-user voice token to the requester's Slack UID.

Voice clients carry no Slack identity, but honeybot must DM "the person
who asked." Each requester's Shortcut / MCP config carries a bearer token;
this resolver maps it to a Slack UID. Fits the identity model in
docs/identity-model.md — the token lives at op://Honeybot/Voice/token_map
(a JSON object of token->UID), resolved into VOICE_TOKEN_MAP at boot.

Fail-closed: an unknown token raises UnknownToken and never reaches the
agent.
"""

from __future__ import annotations


class UnknownToken(Exception):
    """Raised when a presented token maps to no Slack user."""


class Identity:
    def __init__(self, token_map: dict):
        # Copy so later mutation of the source dict can't change auth.
        self._map = dict(token_map)

    def resolve(self, token: str) -> str:
        """Return the Slack UID for a token, or raise UnknownToken.

        Constant-ish behavior: we don't distinguish 'no token' from
        'wrong token' to the caller — both are UnknownToken — so an
        attacker can't tell a malformed request from an unrecognized one.
        """
        uid = self._map.get((token or "").strip())
        if not uid:
            raise UnknownToken("unrecognized voice token")
        return uid
