---
name: voice-token
version: 0.1.0
description: Self-service voice-relay token management. Mint / rotate / revoke the per-user bearer token a voice client (Claude voice, ChatGPT voice, Siri) presents to honeybot's voice-relay.
triggers:
  - "voice token"
  - "generate my voice token"
  - "rotate my voice token"
  - "revoke my voice token"
  - "connect claude voice"
  - "connect chatgpt voice"
  - "my siri token"
capabilities:
  - voice_token_generate
  - voice_token_revoke
  - voice_token_show
---

# Voice Token Skill

> **🔐 OTP Identity Gate**: On Slack, identity is inherent. On Open WebUI /
> API, the caller must complete email OTP verification first (the
> `otp-identity-verification` skill) — this skill resolves the caller's
> Slack UID from that verified session. No default user.

## What this does

Voice assistants (Claude voice, ChatGPT voice, Siri) reach honeybot
through the **voice-relay** (see `docs/voice-relay.md`). Every request
carries a per-user bearer **token** so the relay knows (a) the caller is
authorized and (b) *which Slack user* is asking — so it can DM the result
back when a command outlasts the assistant's response window.

This skill lets a user mint/rotate/revoke their own token by asking
honeybot, instead of hand-editing 1Password or running a script.

## When to use

Any request like "generate my voice token", "I want to connect Claude
voice", "rotate my voice token", "revoke my voice token", "show my voice
token".

## How it works

1. Resolve the caller's Slack UID (Slack sidecar, or OTP-verified session
   on Open WebUI/API — identical precedence to `creds.sh`).
2. Read/modify `op://Honeybot/Voice/token_map` (JSON `{token: slack_uid}`)
   — 1Password is the durable source of truth.
3. Push the full map to the relay's `/admin/tokens` (authenticated by
   `op://Honeybot/Voice/admin_key`) so a fresh token works **immediately**,
   no relay restart.

One active token per user: `generate` replaces any prior token.

## Commands

```bash
# Mint (or rotate) the caller's token — returns the token to paste into
# the voice client's connector/bearer auth.
python3 skills/voice-token/bin/voice-token.py generate

# Same thing.
python3 skills/voice-token/bin/voice-token.py rotate

# Reveal the caller's current token (if any).
python3 skills/voice-token/bin/voice-token.py show

# Revoke the caller's token — it stops working right away.
python3 skills/voice-token/bin/voice-token.py revoke
```

Admin/debug override (skips session identity):

```bash
python3 skills/voice-token/bin/voice-token.py generate --user U09NS7DSK8U
```

## What to tell the user

- **generate/rotate**: hand back the token and tell them to paste it into
  their voice client's connector auth (Claude/ChatGPT MCP connector bearer,
  or a Siri Shortcut `Authorization: Bearer <token>` header). Note it
  replaced any previous token.
- **revoke**: confirm it's dead.
- Never echo tokens into logs or channels beyond the direct reply to the
  requester.

## Failure modes

- Exit 2 — no identity. On Open WebUI/API, run the OTP flow first.
- Exit 4 — identity not verified (OTP). Route to `otp-identity-verification`.
- Exit 3 — 1Password read/write failed (check the service-account token /
  the `Voice` item exists; seed-vault.sh creates it on boot).
- If the live push to the relay fails, the token is still saved to
  1Password and activates on the next deploy — the reply says so.
