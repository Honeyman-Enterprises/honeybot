"""Token/code models — the SDK's, extended to carry the resolved identity.

The MCP SDK is generic over the authorization-code and access-token types
(``AuthorizationCodeT`` / ``AccessTokenT``), so we subclass its models to
carry ``slack_uid`` + ``email``. That's what lets ``ask_honeybot`` read the
identity from the validated access token (``get_access_token()``) instead
of a request header.
"""

from __future__ import annotations

from mcp.server.auth.provider import AccessToken, AuthorizationCode


class HoneybotAuthorizationCode(AuthorizationCode):
    # Base fields: code, scopes, expires_at, client_id, code_challenge,
    # redirect_uri, redirect_uri_provided_explicitly.
    slack_uid: str = ""
    email: str = ""


class HoneybotAccessToken(AccessToken):
    # Base fields: token, client_id, scopes, expires_at.
    slack_uid: str = ""
    email: str = ""
