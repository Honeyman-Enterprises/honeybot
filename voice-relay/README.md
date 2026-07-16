# voice-relay

Thin sidecar that lets voice assistants hand spoken commands to honeybot.
Full design: [`docs/voice-relay.md`](../docs/voice-relay.md).

**Phase 1 (this):** HTTP core + Siri ingress. Answers inline when the
agent is fast; acks + DMs the requester in Slack when it's slow.

## Layout

```
voice_relay/
  types.py            VoiceRequest / VoiceReply (transport-agnostic)
  config.py           env → Config
  identity.py         per-user token → Slack UID (fail-closed)
  registry.py         per-request state + atomic single-delivery claim
  core.py             the fast-ack / async-DM race
  honeybot_client.py  → honeybot api_server /v1/chat/completions
  slack_client.py     → Slack DM (conversations.open + chat.postMessage)
  app.py              FastAPI factory, mounts ingresses
  ingress/
    base.py           Ingress protocol + bearer() helper
    siri.py           POST /v1/voice/ask   (also serves HTTP-only clients)
    __init__.py       ENABLED_INGRESSES  ← add new adapters here
```

## Adding a voice adapter (the plugin point)

1. New module in `voice_relay/ingress/` with a class exposing
   `name: str` and `mount(app, core)`.
2. In `mount`, parse the client's request into a `VoiceRequest`, call
   `await core.handle(req)`, shape the `VoiceReply` back.
3. Add an instance to `ENABLED_INGRESSES` in `ingress/__init__.py`.

The core never changes. Phase 2 adds `mcp.py` (Claude/ChatGPT voice).

## Config (env)

| Var | Source | Default |
|---|---|---|
| `VOICE_RELAY_PORT` | compose | `8080` |
| `VOICE_FAST_ACK_SECONDS` | compose | `3.5` |
| `VOICE_AGENT_TIMEOUT_SECONDS` | compose | `300` |
| `HONEYBOT_API_URL` | compose | `http://honeybot:8642/v1` |
| `HONEYBOT_MODEL` | compose | `honeybot` |
| `HONEYBOT_API_KEY` | `.env.runtime` (= HermesAPI key) | — |
| `SLACK_BOT_TOKEN` | `.env.runtime` | — |
| `VOICE_TOKEN_MAP` | `.env.runtime` (op://Honeybot/Voice/token_map) | `{}` → all 401 |

`VOICE_TOKEN_MAP` is a compact JSON object of bearer-token → Slack UID:

```json
{"tok_eric_abc123":"U04ERIC","tok_michelle_def456":"U05MICHELLE"}
```

Empty map = fail-closed (every request 401s). That's the correct resting
state for a public, action-triggering endpoint.

## Test

Core race-logic tests are stdlib-only (no FastAPI/httpx needed):

```bash
python3 tests/test_core.py     # standalone runner, prints PASS/FAIL
pytest tests/test_core.py       # if pytest is installed
```

## Try it (once wired + a token is populated)

```bash
curl -sS https://voice.honeybot.honeymanenterprises.com/v1/voice/ask \
  -H "Authorization: Bearer $VOICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"what meetings do I have today","request_id":"dev-1"}'
```

Fast → `{"speech":"<answer>","status":"answered"}`.
Slow → `{"speech":"On it — I'll message you in Slack…","status":"accepted"}`
followed by a Slack DM when the agent finishes.
