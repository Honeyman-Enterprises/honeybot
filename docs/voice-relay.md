# Voice Relay — voice assistants → honeybot

**Audience:** future-Eric, future-contributors. Read this before adding a
new voice/assistant front-end (Siri, Claude voice, ChatGPT voice, or the
next one) that hands a spoken command to honeybot.

## What we're building

A user speaks to a voice assistant:

> "Hey Siri, tell honeybot to update the image on honeymanenterprises.com
> to my most recent LinkedIn photo where I'm shown on the site."

The assistant does voice→text and hands the command to honeybot. honeybot:

- **answers inline** if it can do so within the few seconds the assistant
  will wait (a lookup, a status, a yes/no), OR
- **acknowledges** ("On it — I'll message you in Slack when it's done")
  and finishes the work asynchronously, then **DMs the requester in
  Slack** with the result.

Three clients at launch, and a **plugin layer** so the fourth costs a
single small module:

| Client | Transport it speaks |
|---|---|
| Siri (Shortcuts) | HTTP POST only |
| Claude voice | MCP |
| ChatGPT voice | MCP (or a GPT Action / OpenAPI over the same HTTP) |

## Why not "just an MCP"

MCP only reaches clients that speak MCP. Siri does not — a Siri Shortcut
can only do "Get Contents of URL" (HTTP). So the **source of truth is a
plain authenticated HTTP endpoint**, and MCP is a thin shim that calls
the same core. The hard part isn't the front door at all — it's the
async completion loop (answer now if fast, DM Slack later if slow), which
lives behind every front door regardless of transport.

## Reachability / deployment

honeybot's baseline is "no inbound ports" (Slack Socket Mode is
outbound). The voice relay is the deliberate exception: Siri must POST to
a public HTTPS URL. We already run inbound HTTPS for openwebui behind
nginx on a **business static IP with port forwarding**, so this is the
same proven path — one more nginx vhost/route, not new infrastructure.

```
voice.honeybot.honeymanenterprises.com  ──►  nginx  ──►  voice-relay:PORT
```

The relay listens only on the honeynet docker network; nginx terminates
TLS and forwards. No new host-level port beyond what nginx already owns.

## Architecture

```
Siri Shortcut ─────────────┐  HTTP POST /v1/voice/ask
Claude voice (MCP) ────────┤  MCP tool  ask_honeybot(text)
ChatGPT voice (MCP/Action)─┘
                            │  every ingress normalizes to a VoiceRequest
                 ┌──────────▼───────────────────────────────┐
                 │  voice-relay  (thin sidecar container)    │
                 │                                           │
                 │  ingress plugins → core.handle()          │
                 │    1. token → Slack UID (identity)        │
                 │    2. open request in the registry        │
                 │    3. spawn agent run (background task)    │
                 │    4. RACE fast_ack_seconds                │
                 │         hit  → speak the answer           │
                 │         miss → speak "On it…", keep going  │
                 │    5. on background completion:            │
                 │         if not already spoken → Slack DM   │
                 └──────────┬────────────────────────────────┘
                            │  runs the command
                 ┌──────────▼───────────┐        ┌─────────────────┐
                 │ honeybot api_server   │        │ Slack (bot DM)  │
                 │ /v1/chat/completions  │        │ late results    │
                 │ (already live for     │        │                 │
                 │  openwebui)           │        │                 │
                 └───────────────────────┘        └─────────────────┘
```

## The plugin layer (ingress bindings)

The core is transport-agnostic. Each client is a small **ingress
binding** that (a) parses that client's inbound shape into a
`VoiceRequest`, and (b) formats the core's `VoiceReply` back into what
that client expects. Adding a new voice client = drop a new binding
module into `voice_relay/ingress/` and register it. Nothing in the core
changes.

```python
# voice_relay/types.py
from dataclasses import dataclass
from typing import Literal

@dataclass(frozen=True)
class VoiceRequest:
    text: str          # the spoken command, already voice→text'd by the client
    token: str         # per-user bearer token → resolves to a Slack UID
    client: str        # "siri" | "claude-voice" | "chatgpt-voice" | ...
    request_id: str    # client-supplied or relay-generated; idempotency key

@dataclass(frozen=True)
class VoiceReply:
    speech: str                             # what the client says NOW
    status: Literal["answered", "accepted"] # answered=fast path; accepted=async
    request_id: str
```

```python
# voice_relay/ingress/base.py
from typing import Protocol
from voice_relay.core import Core

class Ingress(Protocol):
    """One transport binding (HTTP route set, or MCP tool set)."""
    name: str

    def mount(self, app, core: Core) -> None:
        """Attach this ingress to the running app.

        HTTP ingresses register FastAPI routes that parse the request
        into a VoiceRequest, call `await core.handle(req)`, and shape the
        VoiceReply into the client's response format.

        MCP ingresses register an MCP tool (e.g. ask_honeybot) that does
        the same normalization, then returns reply.speech as the tool
        result.
        """
        ...
```

Launch bindings:

- `ingress/siri.py` — `POST /v1/voice/ask`, body `{ "text": "...",
  "request_id": "..." }`, `Authorization: Bearer <token>`. Returns
  `{ "speech": "...", "status": "..." }`. The Siri Shortcut speaks
  `speech`.
- `ingress/mcp.py` — one MCP server exposing `ask_honeybot(text)`; the
  per-user token comes from the MCP client's configured auth. Serves both
  Claude voice and ChatGPT voice (both speak MCP). ChatGPT can
  alternatively use a GPT Action pointed at the Siri HTTP route — same
  core, no extra code.

## Core lifecycle (the actually-hard part)

Two ideas do all the work:

**1. Don't classify — race a timeout.** You can't reliably predict
"2 seconds or 2 minutes" up front. So don't. Fire the command at the
agent, await its first complete answer for `fast_ack_seconds` (~3–4s).
Landed → speak it. Timed out → return the ack and let the agent finish.
The timeout *is* the classifier.

**2. Async completion → Slack DM.** When the slow path finishes, the
relay DMs the requester in Slack using the bot token. The relay owns
this delivery (see "Integration seam" below), so it needs no Hermes
internals.

```python
# voice_relay/core.py  (shape, not final)
async def handle(self, req: VoiceRequest) -> VoiceReply:
    slack_uid = self.identity.resolve(req.token)      # fail closed if unknown
    self.registry.open(req.request_id, slack_uid, req.text)

    # Background task always runs to completion, regardless of the race.
    task = asyncio.create_task(self._run(req, slack_uid))

    done = await _first_within(task, self.cfg.fast_ack_seconds)
    if done is not _TIMEOUT:
        self.registry.mark_spoken(req.request_id)
        return VoiceReply(done, "answered", req.request_id)

    return VoiceReply(
        "On it — I'll message you in Slack when it's done.",
        "accepted", req.request_id,
    )

async def _run(self, req: VoiceRequest, slack_uid: str) -> str:
    result = await self.honeybot.run(req.text, identity=slack_uid,
                                     request_id=req.request_id)
    # If the fast path already spoke the answer, don't also DM.
    if not self.registry.was_spoken(req.request_id):
        await self.slack.dm(slack_uid, result)
    self.registry.close(req.request_id)
    return result
```

### Idempotent-enough delivery

Per your call: a rare double-send is acceptable. So the "already spoken"
check is a **best-effort flag, not a lock**. In the pathological case
where the agent completes in the same instant the fast-ack fires, the
requester might get the answer spoken *and* a Slack DM. Harmless — same
content, one channel is redundant. We do NOT pay for a distributed lock
or a two-phase commit to prevent a duplicate that costs nothing.

The registry (state honeybot/relay keeps per request):

```
request_id → { slack_uid, text, opened_at, spoken: bool, closed: bool }
```

Held in the relay (in-memory is fine for v1; back it with the existing
Honcho/Redis if you want restart-durability). "hermes should know the
state of a request" is satisfied by this registry being the single place
that knows a request is open, past the timeout, and whether it's been
answered.

## Identity mapping

Voice clients carry no Slack identity, but we must DM "the person who
asked." Each requester's Shortcut / MCP config carries a **per-user
token** that the relay maps to a Slack UID, stored at
`op://Honeybot/Voice/token_map` (JSON `{token: slack_uid}`).
`TokenStore.resolve(token)` fails closed on an unknown token — an
unauthenticated voice request never reaches the agent.

### Self-service token management (built)

Users mint/rotate/revoke their own token by asking honeybot — no script,
no hand-editing 1Password. The `voice-token` skill
(`skills/voice-token/`) is the authority:

1. Resolve the caller's Slack UID — **identical to `creds.sh`**: Slack
   sidecar for Slack sessions, or the **OTP-verified session** for
   Open WebUI / API. This is why no custom Open WebUI extension is needed:
   the existing OTP gate (`otp-identity-verification`, PR #33) already
   binds an Open WebUI user to their Slack UID via email verification —
   using the same `send_email.py` relay from `docs/email-verification.md`.
2. Read/modify `op://Honeybot/Voice/token_map` (durable source of truth).
3. **Push the full map to the relay's `/admin/tokens`** (authed by
   `op://Honeybot/Voice/admin_key`) so a fresh token works immediately —
   no relay restart.

```
Slack DM  ─┐
Open WebUI ┤→ voice-token skill → op://Honeybot/Voice/token_map (truth)
  (OTP)    ┘                    └→ PUT relay /admin/tokens (live)
```

### How the relay learns tokens

- **cold start**: `VOICE_TOKEN_MAP` env, seeded from op by secrets-init at
  every compose up.
- **live**: the skill's `/admin/tokens` push updates the relay in-memory
  and persists to `voice-relay-data:/data/tokens.json`, so freshly minted
  tokens survive a relay restart between compose-ups.
- op is always the durable truth; the env seed + volume are runtime caches.
- `/admin/tokens` is internal-only (blocked at nginx; the skill reaches it
  over honeynet) and requires the admin key even so.

### Open spike: identity into the agent run

The relay knows the requester's Slack UID. For a **pure lookup** the
agent doesn't need it. For a **per-user action** ("update *my* website
image", "check *my* AWS") the agent must resolve per-user creds via
`creds.sh`, which reads the requester's Slack UID from the identity
sidecar (`hooks/honeybot-identity`). The Slack gateway sets that up per
message; the `api_server` path may not. **Before building Phase 2+, spike
how to propagate the requester's Slack UID through `api_server` into the
agent's tool environment** (candidate: a relay-set header the
honeybot-identity hook honors, or passing `--user`-style context the
agent forwards to `creds.sh`). Pure-lookup Phase 1 doesn't block on this.

## Integration seam — how the relay drives honeybot

Two options; we take the self-contained one.

**Chosen: relay → `api_server` + relay owns Slack delivery.**
- The relay calls honeybot's existing OpenAI-compatible `api_server`
  (already up for openwebui) to run the command through the full agent
  (tools + skills).
- The relay holds the Slack **bot token** and DMs the requester itself on
  late completion.
- No dependency on Hermes gateway internals. Fully testable in isolation.

**Deferred: Hermes-native ingest with auto-deliver.** Hermes already has
`HERMES_CRON_AUTO_DELIVER_{PLATFORM,CHAT_ID,THREAD_ID}` contextvars
(`gateway/session_context.py`) that let a job proactively deliver its
result to a target. A future refinement could inject the voice command as
a first-class Hermes platform message with auto-deliver pointed at the
requester's Slack DM, so Hermes owns delivery end-to-end. More elegant,
but couples to Hermes internals — revisit once the `api_server` path is
proven.

## Security

- **The public port triggers real actions** — authenticate every request.
  Bearer token per user (the identity token above), checked before the
  command reaches the agent. No token → 401, no agent run.
- **Rate-limit per token** (N/min). A leaked Shortcut shouldn't be able to
  drive the agent in a loop.
- **Don't echo tokens** in logs or error bodies.
- **nginx**: same TLS/vhost hardening as the openwebui route; the relay
  binds honeynet-only, never the host directly.
- **Scope creep guard**: the relay forwards commands; it does not itself
  decide what honeybot may do. Authorization for individual actions stays
  in the agent/skills layer (allow-lists, confirmations), unchanged.

## Build phases

1. ✅ **Phase 1 — HTTP core + Siri.** `voice-relay` sidecar,
   `ingress/siri.py`, identity resolve, the race/registry, relay→api_server,
   relay→Slack DM on timeout. Full fast-ack/async-DM loop; core unit-tested.
2. ✅ **Phase 2 — MCP ingress + self-service tokens.** `ingress/mcp.py`
   (`ask_honeybot` over Streamable-HTTP for Claude/ChatGPT voice), the
   dynamic `TokenStore` + `/admin/tokens` admin API, and the `voice-token`
   skill (mint/rotate/revoke, op-backed, OTP-gated on Open WebUI). ⚠️ MCP
   transport needs live verification against a real Claude/ChatGPT
   connector — the handshake + bearer passing can't be unit-tested.
3. **Phase 3 — per-user actions.** Resolve the identity-into-api_server
   spike so action commands (website image, AWS, HubSpot) resolve the
   requester's per-user creds. This is the "update my LinkedIn photo on
   the site" case. The relay already sends the requester's UID as the
   OpenAI `user` field + `X-Honeybot-Slack-User` header; the honeybot side
   must honor one of them so `creds.sh` resolves per-user credentials.
4. **Phase 4 — durability & polish.** Back the registry with Honcho/Redis
   for restart survival; per-token rate limits; a fourth adapter to prove
   the plugin layer (e.g. a generic webhook for Home Assistant / Alexa).

## Local development

Run the relay standalone against a stub `api_server` (or the real one on
the laptop) and curl the Siri route:

```bash
curl -sS https://voice.honeybot.honeymanenterprises.com/v1/voice/ask \
  -H "Authorization: Bearer $VOICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"what meetings do I have today","request_id":"dev-1"}'
```

Expect either `{"speech":"<answer>","status":"answered"}` (fast) or
`{"speech":"On it — I'll message you in Slack…","status":"accepted"}`
(slow) followed by a Slack DM when the agent finishes.
