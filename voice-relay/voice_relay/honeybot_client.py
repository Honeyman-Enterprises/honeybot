"""Drive honeybot's agent via its OpenAI-compatible api_server.

The api_server (/v1/chat/completions) is already live on the honeybot
container for Open WebUI; we reuse it. A single non-streaming completion
runs the full agent (tools + skills) and returns the final text.

Identity propagation (the Phase-3 spike from docs/voice-relay.md): we
pass the requester's Slack UID both as the OpenAI `user` field and as an
X-Honeybot-Slack-User header. For pure lookups the agent doesn't need it;
for per-user actions the agent/hooks must honor one of these so creds.sh
resolves the right per-user credentials. Header is set now so the wiring
is ready when the hook side lands — it's inert until then.
"""

from __future__ import annotations

import httpx


class HoneybotClient:
    def __init__(self, base_url: str, api_key: str, model: str, timeout: float):
        self._url = f"{base_url}/chat/completions"
        self._key = api_key
        self._model = model
        self._timeout = timeout

    async def run(self, text: str, *, identity: str, request_id: str) -> str:
        headers = {
            "Authorization": f"Bearer {self._key}",
            "Content-Type": "application/json",
            # Identity hint for per-user credential resolution (Phase 3).
            "X-Honeybot-Slack-User": identity,
            "X-Voice-Request-Id": request_id,
        }
        payload = {
            "model": self._model,
            "messages": [{"role": "user", "content": text}],
            "stream": False,
            "user": identity,
        }
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.post(self._url, headers=headers, json=payload)
            resp.raise_for_status()
            data = resp.json()
        return self._extract(data)

    @staticmethod
    def _extract(data: dict) -> str:
        try:
            content = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as e:
            raise RuntimeError(f"unexpected api_server response shape: {e}") from e
        if content is None:
            raise RuntimeError("api_server returned an empty message")
        return content.strip()
