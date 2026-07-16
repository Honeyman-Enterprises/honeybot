"""Deliver late results to the requester's Slack DM.

Uses the bot token (op://Honeybot/Slack Bot/bot_token). Opening a DM is
two calls: conversations.open to get (or reuse) the IM channel for the
user, then chat.postMessage. Requires the bot scopes im:write + chat:write
(already granted — the gateway uses them).
"""

from __future__ import annotations

import httpx

_SLACK_API = "https://slack.com/api"


class SlackClient:
    def __init__(self, bot_token: str):
        self._token = bot_token

    async def dm(self, slack_uid: str, text: str) -> None:
        headers = {
            "Authorization": f"Bearer {self._token}",
            "Content-Type": "application/json; charset=utf-8",
        }
        async with httpx.AsyncClient(timeout=30) as client:
            opened = await client.post(
                f"{_SLACK_API}/conversations.open",
                headers=headers,
                json={"users": slack_uid},
            )
            opened.raise_for_status()
            body = opened.json()
            if not body.get("ok"):
                raise RuntimeError(f"conversations.open failed: {body.get('error')}")
            channel = body["channel"]["id"]

            posted = await client.post(
                f"{_SLACK_API}/chat.postMessage",
                headers=headers,
                json={"channel": channel, "text": text},
            )
            posted.raise_for_status()
            body = posted.json()
            if not body.get("ok"):
                raise RuntimeError(f"chat.postMessage failed: {body.get('error')}")
