"""Core race-logic tests — stdlib only, no FastAPI/httpx needed.

Runnable two ways:
    python3 tests/test_core.py       # standalone, prints PASS/FAIL
    pytest tests/test_core.py         # if pytest is installed

Covers the three branches that matter:
  1. fast path  → answered inline, NO Slack DM
  2. slow path  → accepted ack, result arrives via exactly one Slack DM
  3. fast error → friendly spoken error, no crash
and the no-double-delivery invariant on the boundary.
"""

from __future__ import annotations

import asyncio
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from voice_relay.config import Config
from voice_relay.core import Core
from voice_relay.identity import TokenStore, UnknownToken
from voice_relay.registry import Registry
from voice_relay.types import VoiceRequest


class FakeHoneybot:
    def __init__(self, delay, result="the answer", raises=None):
        self.delay = delay
        self.result = result
        self.raises = raises
        self.calls = 0

    async def run(self, text, *, identity, request_id):
        self.calls += 1
        await asyncio.sleep(self.delay)
        if self.raises:
            raise self.raises
        return self.result


class FakeSlack:
    def __init__(self):
        self.dms = []

    async def dm(self, slack_uid, text):
        self.dms.append((slack_uid, text))


def _config(fast_ack=0.05):
    return Config(
        port=8080,
        fast_ack_seconds=fast_ack,
        agent_timeout_seconds=5,
        honeybot_api_url="http://x/v1",
        honeybot_api_key="k",
        honeybot_model="m",
        slack_bot_token="xoxb-test",
        token_map={"tok-eric": "U04ERIC"},
        ack_message="On it — Slack incoming.",
        token_store_path="",  # no persistence in unit tests
        admin_key="admin-secret",
    )


def _core(honeybot, slack, cfg=None):
    cfg = cfg or _config()
    return Core(
        identity=TokenStore(cfg.token_map, store_path=None),
        registry=Registry(),
        honeybot=honeybot,
        slack=slack,
        config=cfg,
    ), cfg


def _req(text="what's on my calendar", token="tok-eric", rid="r1"):
    return VoiceRequest(text=text, token=token, client="siri", request_id=rid)


async def _drain():
    # Let scheduled background tasks (late delivery) finish.
    await asyncio.sleep(0.15)


def test_fast_path_answers_inline_no_dm():
    async def run():
        hb = FakeHoneybot(delay=0.001, result="3 meetings")
        slack = FakeSlack()
        core, _ = _core(hb, slack)
        reply = await core.handle(_req())
        assert reply.status == "answered", reply.status
        assert reply.speech == "3 meetings", reply.speech
        await _drain()
        assert slack.dms == [], f"fast path must not DM: {slack.dms}"
    asyncio.run(run())


def test_slow_path_acks_then_dms_once():
    async def run():
        hb = FakeHoneybot(delay=0.2, result="done: image updated")
        slack = FakeSlack()
        core, cfg = _core(hb, slack)
        reply = await core.handle(_req())
        assert reply.status == "accepted", reply.status
        assert reply.speech == cfg.ack_message, reply.speech
        assert slack.dms == [], "no DM yet — agent still working"
        await asyncio.sleep(0.3)  # let the agent finish + deliver
        assert slack.dms == [("U04ERIC", "done: image updated")], slack.dms
    asyncio.run(run())


def test_fast_error_speaks_friendly_no_crash():
    async def run():
        hb = FakeHoneybot(delay=0.001, raises=RuntimeError("boom"))
        slack = FakeSlack()
        core, _ = _core(hb, slack)
        reply = await core.handle(_req())
        assert reply.status == "answered", reply.status
        assert "couldn't finish" in reply.speech.lower(), reply.speech
        await _drain()
        assert slack.dms == [], "errored fast path must not also DM"
    asyncio.run(run())


def test_slow_error_dms_friendly():
    async def run():
        hb = FakeHoneybot(delay=0.2, raises=RuntimeError("boom"))
        slack = FakeSlack()
        core, _ = _core(hb, slack)
        reply = await core.handle(_req())
        assert reply.status == "accepted"
        await asyncio.sleep(0.3)
        assert len(slack.dms) == 1, slack.dms
        assert "couldn't finish" in slack.dms[0][1].lower(), slack.dms
    asyncio.run(run())


def test_unknown_token_rejected_before_agent():
    async def run():
        hb = FakeHoneybot(delay=0.001)
        slack = FakeSlack()
        core, _ = _core(hb, slack)
        raised = False
        try:
            await core.handle(_req(token="tok-nope"))
        except UnknownToken:
            raised = True
        assert raised, "unknown token must raise"
        assert hb.calls == 0, "agent must not run for an unknown token"
    asyncio.run(run())


def test_token_store_live_replace_takes_effect():
    # A freshly pushed token resolves immediately; a revoked one stops.
    store = TokenStore({"tok-eric": "U04ERIC"}, store_path=None)
    assert store.resolve("tok-eric") == "U04ERIC"
    store.replace({"tok-eric": "U04ERIC", "tok-michelle": "U05MICHELLE"})
    assert store.resolve("tok-michelle") == "U05MICHELLE"
    store.replace({"tok-michelle": "U05MICHELLE"})  # eric revoked
    raised = False
    try:
        store.resolve("tok-eric")
    except UnknownToken:
        raised = True
    assert raised, "revoked token must stop resolving"


def _all_tests():
    return [v for k, v in sorted(globals().items()) if k.startswith("test_")]


if __name__ == "__main__":
    failures = 0
    for fn in _all_tests():
        try:
            fn()
            print(f"PASS  {fn.__name__}")
        except AssertionError as e:
            failures += 1
            print(f"FAIL  {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failures += 1
            print(f"ERROR {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(_all_tests()) - failures}/{len(_all_tests())} passed")
    sys.exit(1 if failures else 0)
