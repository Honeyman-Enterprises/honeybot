"""The fast-ack / async-DM state machine.

Two ideas do all the work (see docs/voice-relay.md):

1. Don't classify request duration up front — RACE a timeout. Fire the
   command at the agent, await its result for `fast_ack_seconds`. Landed
   in time → speak it. Timed out → return the ack and let the agent
   finish, delivering the late result to Slack.

2. Exactly one delivery path wins, via the registry's atomic claim. Fast
   path claims → speaks. Slow path claims → DMs. They're mutually
   exclusive by branch AND guarded by the claim, so no duplicate.
"""

from __future__ import annotations

import asyncio
import logging

from voice_relay.types import VoiceReply, VoiceRequest

log = logging.getLogger("voice_relay.core")


class Core:
    def __init__(self, *, identity, registry, honeybot, slack, config):
        self.identity = identity
        self.registry = registry
        self.honeybot = honeybot
        self.slack = slack
        self.config = config

    async def handle(self, req: VoiceRequest) -> VoiceReply:
        # Resolve identity first — an unknown token never reaches the agent.
        # (Raises UnknownToken; the ingress maps that to 401.)
        slack_uid = self.identity.resolve(req.token)
        self.registry.open(req.request_id, slack_uid, req.text, req.client)

        # The agent run is one task; both the fast path and the slow path
        # observe the SAME task. asyncio.wait() with a timeout does NOT
        # cancel the task when the timeout fires — on timeout the work
        # keeps running in the background (no shield needed, which also
        # avoids shield's "exception in shielded future" log noise).
        task = asyncio.create_task(self._produce(req, slack_uid))
        self.registry.track(task)

        done, _pending = await asyncio.wait(
            {task}, timeout=self.config.fast_ack_seconds
        )

        if task not in done:
            # Slow path: hand back the ack; deliver the result to Slack
            # when the agent finishes.
            self.registry.track(
                asyncio.create_task(self._deliver_late(task, req, slack_uid))
            )
            return VoiceReply(self.config.ack_message, "accepted", req.request_id)

        # Fast path: the task finished inside the window. Claim so nothing
        # else can double-deliver, then speak the result (or a friendly
        # error). task.result() retrieves the exception cleanly.
        self.registry.claim(req.request_id)
        self.registry.close(req.request_id)
        try:
            result = task.result()
        except Exception as e:  # agent failed fast — speak a friendly error
            log.exception("agent failed within fast window for %s", req.request_id)
            return VoiceReply(self._friendly_error(e), "answered", req.request_id)
        return VoiceReply(result, "answered", req.request_id)

    async def _produce(self, req: VoiceRequest, slack_uid: str) -> str:
        """Run the command through honeybot's agent. Result only — no delivery."""
        return await self.honeybot.run(
            req.text, identity=slack_uid, request_id=req.request_id
        )

    async def _deliver_late(self, task, req: VoiceRequest, slack_uid: str) -> None:
        """Await the (already-running) agent task and DM the requester."""
        try:
            result = await task
        except Exception as e:
            log.exception("agent failed (async) for %s", req.request_id)
            result = self._friendly_error(e, spoken=False)

        if self.registry.claim(req.request_id):
            try:
                await self.slack.dm(slack_uid, result)
            except Exception:
                log.exception("slack DM failed for %s", req.request_id)
        self.registry.close(req.request_id)

    @staticmethod
    def _friendly_error(e: Exception, spoken: bool = True) -> str:
        """User-facing error text. Never leaks internals into voice/Slack."""
        base = "Sorry — I couldn't finish that request."
        return base if spoken else f"{base} ({type(e).__name__})"
