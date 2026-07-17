"""State for the authorization server.

  - clients      DCR registrations (persisted — a connector shouldn't have
                 to re-register after a relay restart)
  - access/refresh tokens (persisted — a connector shouldn't be logged out
                 by a restart)
  - pending      in-flight /authorize requests keyed by our Google `state`
                 (in-memory, short-lived)
  - codes        our issued authorization codes (in-memory, short-lived,
                 one-time-use)

Persistence is a single JSON file (atomic write, 0600) when a path is
given, else pure in-memory (tests). Codes/pending are never persisted —
they live seconds.
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
import time
from dataclasses import asdict, dataclass, field
from typing import Optional


@dataclass
class TokenRecord:
    slack_uid: str
    email: str
    client_id: str
    scopes: list
    expires_at: int          # epoch seconds; 0 = no expiry (refresh tokens)
    refresh_token: str = ""  # paired refresh token, for access tokens


class Store:
    def __init__(self, path: Optional[str] = None):
        self._path = path
        self._lock = threading.Lock()
        self._clients: dict = {}                  # client_id -> client JSON (dict)
        self._access: dict[str, TokenRecord] = {}  # token -> record
        self._refresh: dict[str, TokenRecord] = {}  # token -> record
        self._pending: dict[str, dict] = {}       # state -> pending (in-mem)
        self._codes: dict = {}                    # code -> HoneybotAuthorizationCode (in-mem)
        self._load()

    # ---- clients (persisted) ----------------------------------------------
    def get_client(self, client_id: str) -> Optional[dict]:
        with self._lock:
            return self._clients.get(client_id)

    def put_client(self, client_id: str, client_json: dict) -> None:
        with self._lock:
            self._clients[client_id] = client_json
            self._persist()

    # ---- pending authorize (in-memory) ------------------------------------
    def put_pending(self, state: str, data: dict) -> None:
        with self._lock:
            self._pending[state] = {**data, "created_at": time.time()}

    def pop_pending(self, state: str, max_age: float = 600) -> Optional[dict]:
        with self._lock:
            data = self._pending.pop(state, None)
        if not data:
            return None
        if time.time() - data.get("created_at", 0) > max_age:
            return None
        return data

    # ---- authorization codes (in-memory, one-time) ------------------------
    def put_code(self, code: str, obj) -> None:
        with self._lock:
            self._codes[code] = obj

    def get_code(self, code: str):
        with self._lock:
            return self._codes.get(code)

    def pop_code(self, code: str):
        with self._lock:
            return self._codes.pop(code, None)

    # ---- tokens (persisted) -----------------------------------------------
    def put_access(self, token: str, rec: TokenRecord) -> None:
        with self._lock:
            self._access[token] = rec
            self._persist()

    def get_access(self, token: str) -> Optional[TokenRecord]:
        with self._lock:
            return self._access.get(token)

    def put_refresh(self, token: str, rec: TokenRecord) -> None:
        with self._lock:
            self._refresh[token] = rec
            self._persist()

    def get_refresh(self, token: str) -> Optional[TokenRecord]:
        with self._lock:
            return self._refresh.get(token)

    def revoke(self, token: str) -> None:
        with self._lock:
            self._access.pop(token, None)
            self._refresh.pop(token, None)
            self._persist()

    # ---- persistence ------------------------------------------------------
    def _load(self) -> None:
        if not self._path or not os.path.exists(self._path):
            return
        try:
            with open(self._path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError):
            return
        self._clients = data.get("clients", {})
        self._access = {t: TokenRecord(**r) for t, r in data.get("access", {}).items()}
        self._refresh = {t: TokenRecord(**r) for t, r in data.get("refresh", {}).items()}

    def _persist(self) -> None:
        if not self._path:
            return
        payload = {
            "clients": self._clients,
            "access": {t: asdict(r) for t, r in self._access.items()},
            "refresh": {t: asdict(r) for t, r in self._refresh.items()},
        }
        try:
            os.makedirs(os.path.dirname(self._path), exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(self._path))
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(payload, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self._path)
        except OSError:
            pass
