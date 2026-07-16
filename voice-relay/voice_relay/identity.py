"""Token store: map a per-user voice token to the requester's Slack UID.

Voice clients carry no Slack identity, but honeybot must DM "the person
who asked." Each requester's client config carries a bearer token; this
store maps it to a Slack UID. Fail-closed: an unknown token raises
UnknownToken and never reaches the agent.

Source of truth is 1Password (op://Honeybot/Voice/token_map), owned by
honeybot's voice-token skill. The relay can't read op, so it learns the
map two ways:

  - cold start: VOICE_TOKEN_MAP env (seeded from op by secrets-init at
    every compose up)
  - live: the voice-token skill PUTs the full map to /admin/tokens when a
    user mints/rotates/revokes, so a fresh token works without a restart

Live pushes are persisted to a small volume file so a relay restart
(without a fresh push) keeps the last known map. Priority at load:
persisted file (most recent push) if present, else the env seed.
"""

from __future__ import annotations

import json
import logging
import os
import tempfile
import threading

log = logging.getLogger("voice_relay.identity")


class UnknownToken(Exception):
    """Raised when a presented token maps to no Slack user."""


class TokenStore:
    def __init__(self, env_map: dict, store_path: str | None = None):
        self._env_map = dict(env_map)
        self._store_path = store_path
        self._lock = threading.Lock()
        self._map = self._load()

    def _load(self) -> dict:
        """Persisted push wins over the env seed; env is the cold-start fallback."""
        if self._store_path and os.path.exists(self._store_path):
            try:
                with open(self._store_path, encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, dict):
                    log.info("loaded %d token(s) from %s", len(data), self._store_path)
                    return {str(k): str(v) for k, v in data.items()}
                log.error("%s is not a JSON object; using env seed", self._store_path)
            except (OSError, json.JSONDecodeError) as e:
                log.error("could not read %s (%s); using env seed", self._store_path, e)
        return dict(self._env_map)

    def resolve(self, token: str) -> str:
        """Return the Slack UID for a token, or raise UnknownToken.

        'No token' and 'wrong token' both raise UnknownToken — an attacker
        can't distinguish a malformed request from an unrecognized one.
        """
        with self._lock:
            uid = self._map.get((token or "").strip())
        if not uid:
            raise UnknownToken("unrecognized voice token")
        return uid

    def replace(self, new_map: dict) -> int:
        """Replace the entire token map (admin push) and persist it.

        Returns the number of tokens now active.
        """
        clean = {str(k).strip(): str(v).strip() for k, v in new_map.items() if k and v}
        with self._lock:
            self._map = clean
            self._persist(clean)
        log.info("token map replaced via admin push: %d token(s)", len(clean))
        return len(clean)

    def _persist(self, data: dict) -> None:
        if not self._store_path:
            return
        try:
            os.makedirs(os.path.dirname(self._store_path), exist_ok=True)
            # Atomic write, 0600 — the file holds routing tokens.
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(self._store_path))
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self._store_path)
        except OSError as e:
            log.error("could not persist token map to %s: %s", self._store_path, e)

    def count(self) -> int:
        with self._lock:
            return len(self._map)

    def masked(self) -> dict:
        """Admin list view — tokens masked, UIDs shown (for debugging)."""
        with self._lock:
            return {_mask(tok): uid for tok, uid in self._map.items()}


def _mask(token: str) -> str:
    if len(token) <= 8:
        return "****"
    return f"{token[:4]}…{token[-4:]}"
