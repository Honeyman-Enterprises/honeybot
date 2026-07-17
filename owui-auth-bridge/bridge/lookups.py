"""Authoritative-source lookups (the round-trip HTTP calls).

Kept separate from verify.py so the verification *decisions* stay pure and
unit-tested with fakes, while these do the real network I/O. Both are
synchronous (urllib); the app runs them off the event loop via
asyncio.to_thread.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable, Optional


def slack_lookup_factory(bot_token: str) -> Callable[[str], Optional[dict]]:
    """email -> Slack `user` object (from users.lookupByEmail) or None."""
    def lookup(email: str) -> Optional[dict]:
        if not bot_token or not email:
            return None
        url = "https://slack.com/api/users.lookupByEmail?" + urllib.parse.urlencode({"email": email})
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {bot_token}"})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.load(resp)
        except (urllib.error.URLError, OSError, json.JSONDecodeError):
            return None
        return data.get("user") if data.get("ok") else None

    return lookup


def owui_lookup_factory(base_url: str, api_key: str) -> Optional[Callable[[str], Optional[dict]]]:
    """user_id -> Open WebUI user dict (must include `email`) or None.

    Returns None (disabled) when base_url/api_key aren't configured. NOTE:
    the exact OWUI endpoint shape varies by version and may not return
    `email`; verify against your deployed version before enabling
    BRIDGE_REQUIRE_OWUI. When it doesn't return email, the mismatch check
    fails closed — which is the safe direction.
    """
    if not base_url or not api_key:
        return None
    base = base_url.rstrip("/")

    def lookup(user_id: str) -> Optional[dict]:
        if not user_id:
            return None
        url = f"{base}/api/v1/users/{urllib.parse.quote(user_id, safe='')}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {api_key}"})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.load(resp)
        except (urllib.error.URLError, OSError, json.JSONDecodeError):
            return None
        return data if isinstance(data, dict) else None

    return lookup
