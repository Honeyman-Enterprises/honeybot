"""Resolve a Slack UID from an email (for the OAuth provider).

Same mechanism honeybot's otp_auth + the auth-bridge use: Slack
users.lookupByEmail (needs the bot's users:read.email scope). Fails closed
(returns "") on any error — the provider refuses to mint a token when the
email resolves to no Slack user.

Synchronous urllib on purpose: the provider's Google callback runs in a
request handler; keep it dependency-light and call it off the event loop
if needed.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable


def resolver(bot_token: str) -> Callable[[str], str]:
    """Return a callable(email) -> slack_uid | ""."""
    def resolve(email: str) -> str:
        if not bot_token or not email:
            return ""
        url = "https://slack.com/api/users.lookupByEmail?" + urllib.parse.urlencode({"email": email})
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {bot_token}"})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.load(resp)
        except (urllib.error.URLError, OSError, json.JSONDecodeError):
            return ""
        if data.get("ok") and isinstance(data.get("user"), dict):
            uid = data["user"].get("id", "") or ""
            # Reject bots / deleted just in case.
            if data["user"].get("is_bot") or data["user"].get("deleted"):
                return ""
            return uid
        return ""

    return resolve
