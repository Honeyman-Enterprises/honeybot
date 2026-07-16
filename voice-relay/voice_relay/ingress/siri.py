"""Siri ingress — plain authenticated HTTP.

A Siri Shortcut dictates the command, POSTs it here with the user's
bearer token, and speaks the `speech` field of the JSON response. This is
also the endpoint a ChatGPT GPT Action or any HTTP-only client can target
(MCP-native clients use the MCP ingress instead, added in Phase 2).

  POST /v1/voice/ask
  Authorization: Bearer <per-user token>
  { "text": "<command>", "request_id": "<optional client id>" }

  200 → { "speech": "...", "status": "answered"|"accepted", "request_id": "..." }
  400 → missing/blank text
  401 → unknown token
"""

from __future__ import annotations

import uuid

from fastapi import Header, HTTPException
from pydantic import BaseModel

from voice_relay.core import Core
from voice_relay.identity import UnknownToken
from voice_relay.ingress.base import bearer
from voice_relay.types import VoiceRequest


class _AskBody(BaseModel):
    text: str
    request_id: str | None = None


class SiriIngress:
    name = "siri"

    def mount(self, app, core: Core) -> None:
        @app.post("/v1/voice/ask")
        async def ask(body: _AskBody, authorization: str = Header(default="")):
            text = (body.text or "").strip()
            if not text:
                raise HTTPException(status_code=400, detail="missing 'text'")

            request_id = (body.request_id or "").strip() or f"siri-{uuid.uuid4().hex[:12]}"
            req = VoiceRequest(
                text=text,
                token=bearer(authorization),
                client=self.name,
                request_id=request_id,
            )
            try:
                reply = await core.handle(req)
            except UnknownToken:
                raise HTTPException(status_code=401, detail="unauthorized")

            return {
                "speech": reply.speech,
                "status": reply.status,
                "request_id": reply.request_id,
            }
