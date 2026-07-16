"""Admin API — honeybot's voice-token skill pushes the live token map here.

1Password is the source of truth; the skill owns it. After any mint /
rotate / revoke the skill PUTs the full token map here so a fresh token
works without restarting the relay. Authenticated by a shared admin key
(op://Honeybot/Voice/admin_key); if that key is unset the admin API is
disabled entirely — no unauthenticated admin surface.

This is not a voice ingress (no voice client calls it), so it mounts
separately from the ingress plugin layer.
"""

from __future__ import annotations

import hmac
import logging

from fastapi import Header, HTTPException
from pydantic import BaseModel

from voice_relay.identity import TokenStore

log = logging.getLogger("voice_relay.admin")


class _TokensBody(BaseModel):
    # Full replacement map: {token: slack_uid}. The skill always pushes the
    # complete map (it's cheap and idempotent), so the relay's runtime state
    # is exactly the last push.
    tokens: dict


def mount_admin(app, store: TokenStore, admin_key: str) -> None:
    def _authorize(authorization: str) -> None:
        if not admin_key:
            # Disabled: no key configured → no admin surface at all.
            raise HTTPException(status_code=404, detail="not found")
        presented = authorization[7:].strip() if authorization.lower().startswith("bearer ") else authorization.strip()
        # Constant-time compare so a timing side channel can't leak the key.
        if not hmac.compare_digest(presented, admin_key):
            raise HTTPException(status_code=401, detail="unauthorized")

    @app.put("/admin/tokens")
    async def put_tokens(body: _TokensBody, authorization: str = Header(default="")):
        _authorize(authorization)
        active = store.replace(body.tokens)
        return {"active": active}

    @app.get("/admin/tokens")
    async def list_tokens(authorization: str = Header(default="")):
        _authorize(authorization)
        return {"active": store.count(), "tokens": store.masked()}

    log.info("admin API mounted (%s)", "enabled" if admin_key else "disabled")
