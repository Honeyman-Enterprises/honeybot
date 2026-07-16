"""Per-request state + single-delivery claim.

Holds one Entry per in-flight request so the relay always knows a
request is open, whether it's past the fast-ack timeout, and — via the
claim flag — whether it's already been delivered (spoken or DM'd).

The claim is the whole concurrency story. `claim()` does a check-and-set
with no `await` between the read and the write, so in single-threaded
asyncio it's atomic: exactly one of {fast path, slow path} wins and
delivers. A duplicate is therefore impossible in normal flow — but even
if one slipped through, the payload is identical and harmless, so we
deliberately do NOT reach for a distributed lock (see docs/voice-relay.md
"idempotent-enough delivery").

v1 is in-memory: a relay restart forgets in-flight requests. That's
acceptable for Phase 1 (a dropped in-flight request just doesn't get its
late Slack DM). Phase 4 backs this with Honcho/Redis for durability.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class Entry:
    slack_uid: str
    text: str
    client: str
    opened_at: float = field(default_factory=time.time)
    delivered: bool = False
    closed: bool = False


class Registry:
    def __init__(self):
        self._entries: dict[str, Entry] = {}
        # Keep strong refs to background tasks so they aren't GC'd mid-flight.
        self._tasks: set = set()

    def open(self, request_id: str, slack_uid: str, text: str, client: str) -> None:
        self._entries[request_id] = Entry(slack_uid=slack_uid, text=text, client=client)

    def claim(self, request_id: str) -> bool:
        """Atomically claim delivery. True = you won, go deliver.

        No `await` between read and write → atomic under asyncio.
        """
        entry = self._entries.get(request_id)
        if entry is None or entry.delivered:
            return False
        entry.delivered = True
        return True

    def close(self, request_id: str) -> None:
        entry = self._entries.get(request_id)
        if entry is not None:
            entry.closed = True

    def track(self, task) -> None:
        """Retain a background task; auto-drop when it finishes."""
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def snapshot(self) -> dict:
        """Debug view of current state (no secrets)."""
        return {
            rid: {
                "slack_uid": e.slack_uid,
                "client": e.client,
                "age_s": round(time.time() - e.opened_at, 2),
                "delivered": e.delivered,
                "closed": e.closed,
            }
            for rid, e in self._entries.items()
        }

    def get(self, request_id: str) -> Optional[Entry]:
        return self._entries.get(request_id)
