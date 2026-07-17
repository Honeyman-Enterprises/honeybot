"""Google as the upstream identity provider.

Two pieces: build the Google authorization URL we redirect the user to, and
exchange the code Google hands back for the user's verified email.

The id_token is obtained over a direct server-to-server TLS call to Google's
token endpoint, authenticated with our client secret — so the token is
authentic and we read the email from its payload. (We still check
``email_verified`` and, at the provider layer, the allowed domain.)
"""

from __future__ import annotations

import base64
import json
import urllib.error
import urllib.parse
import urllib.request

_GOOGLE_AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
_GOOGLE_TOKEN = "https://oauth2.googleapis.com/token"


def auth_url(*, client_id: str, redirect_uri: str, state: str,
             scope: str = "openid email") -> str:
    """The Google consent URL to redirect the user to."""
    return _GOOGLE_AUTH + "?" + urllib.parse.urlencode({
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": scope,
        "state": state,
        "access_type": "online",
        "prompt": "select_account",
    })


class GoogleError(Exception):
    pass


def exchange_code_for_email(*, code: str, client_id: str, client_secret: str,
                            redirect_uri: str) -> str:
    """Exchange a Google auth code for the user's verified email.

    Raises GoogleError on any failure (network, non-2xx, unverified email,
    missing email). Returns the lower-cased email.
    """
    body = urllib.parse.urlencode({
        "code": code,
        "client_id": client_id,
        "client_secret": client_secret,
        "redirect_uri": redirect_uri,
        "grant_type": "authorization_code",
    }).encode()
    req = urllib.request.Request(
        _GOOGLE_TOKEN, data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.load(resp)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
        raise GoogleError(f"google token exchange failed: {e}") from e

    id_token = data.get("id_token")
    if not id_token:
        raise GoogleError("google response had no id_token")
    claims = _decode_jwt_payload(id_token)
    email = (claims.get("email") or "").strip().lower()
    if not email:
        raise GoogleError("id_token had no email")
    # email_verified may be a bool or the string "true".
    verified = claims.get("email_verified")
    if verified not in (True, "true", "True"):
        raise GoogleError(f"email {email} is not verified by Google")
    return email


def _decode_jwt_payload(token: str) -> dict:
    """Decode the payload segment of a JWT (no signature check — see module
    docstring: the token came straight from Google over our TLS backchannel)."""
    parts = token.split(".")
    if len(parts) != 3:
        raise GoogleError("malformed id_token")
    payload = parts[1]
    payload += "=" * (-len(payload) % 4)  # pad base64url
    try:
        return json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, json.JSONDecodeError) as e:
        raise GoogleError(f"could not decode id_token payload: {e}") from e
