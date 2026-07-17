# Google login → skip OTP (identity synergy)

**Status: built; needs end-to-end verification on the running stack.** The
primitives, the Open WebUI toggles, the `owui-auth-bridge`, and the hook
that closes the loop are all in. The security core (round-trip
verification) is unit-tested (12/12). The cross-container seams (shared
auth volume perms, header propagation, session-key → creds.sh) can't be
unit-tested from the repo — verify them live per the checklist below.

## The idea

A user who signs into Open WebUI with **Google** has already proven they
control their Workspace email — Google asserts it directly. That's a
*stronger* proof than the email-OTP gate (`otp-identity-verification`),
which mails a code to the same address. So a Google-authenticated Open
WebUI session should not have to do the OTP dance again before honeybot
reads their per-user credentials (Gmail, AWS, …).

## The blocker (verified against Hermes source)

For this to work, the Google-verified **email** has to reach the honeybot
side and get turned into a verified identity session. Two facts from
`gateway/platforms/api_server.py` (Hermes) shape the design:

1. The api_server derives a session identity from the **`X-Hermes-Session-Key`**
   request header (API-key-gated). That's the lever for giving a session a
   stable, identity-bearing key like `openwebui:{slack_uid}`.
2. The api_server **ignores** Open WebUI's `X-OpenWebUI-User-*` headers. So
   even with `ENABLE_FORWARD_USER_INFO_HEADERS=true`, the forwarded email
   lands nowhere honeybot consumes it.

**There is no native bridge** between "Open WebUI forwards
`X-OpenWebUI-User-Email`" and "the api_server wants `X-Hermes-Session-Key`."
That gap is the whole remaining task.

## What's built (this PR)

- **Open WebUI** (`docker-compose.yml`): `ENABLE_LOGIN_FORM=false`
  (Google-only) and `ENABLE_FORWARD_USER_INFO_HEADERS=true` (forward the
  authenticated user's email/id/name/role downstream — the prerequisite).
- **`skills/_lib/otp_auth.py`** — two primitives, unit-tested
  (`skills/_lib/tests/test_otp_trust.py`):
  - `establish_trusted_session(email, slack_uid, session_key, interface)` —
    mints a verified session **without an OTP code**, for callers that
    already proved identity by a stronger factor (OAuth). Keyed exactly the
    way `creds.sh` looks the gate up, so it's actually found. (Fixed a
    latent key-mismatch while here: the store key must NOT include the
    email, because the gate checks without one.)
  - `slack_uid_for_email(email)` — resolves email → Slack UID via
    `users.lookupByEmail` (needs the bot's `users:read.email` scope). Fails
    closed (returns "").
  - CLI: `otp_auth.py trust --email … --session-key … [--uid …]`.

## The bridge (built — `owui-auth-bridge/`)

Open WebUI points its OpenAI connection at the bridge
(`OPENAI_API_BASE_URL: http://owui-auth-bridge:8080/v1`) instead of
`honeybot:8642`. Per request the bridge:

1. **Gate** — require the api_server bearer (only Open WebUI has it; the
   bridge is honeynet-only) and **strip any client-supplied
   `X-Hermes-Session-Key`** so a caller can't assert its own identity.
2. **Round-trip verify** (`bridge/verify.py`) — take ONLY the claimed
   email, resolve the UID from **Slack** (`users.lookupByEmail`), confirm
   the account is active/human and the email/domain match, and (optionally)
   confirm the `(user_id, email)` pair against Open WebUI's DB. The minted
   UID never comes from the header.
3. **Mint** a trusted session for `openwebui:{slack_uid}`
   (`establish_trusted_session`) into the shared `honeybot-auth` volume.
4. **Inject** `X-Hermes-Session-Key: openwebui:{slack_uid}` and forward to
   `honeybot:8642`.
5. **Fail closed** — on any verification/mint failure, forward with NO
   session key. The session stays unverified and falls back to OTP.

Closing the loop **without touching `creds.sh`**: the `honeybot-identity`
hook now, for non-Slack sessions, resolves the Slack UID from the verified
session (`otp_auth.check_session`) and writes the usual per-session sidecar
— so `creds.sh` gets the UID via its existing path (no `--user`, no OTP
prompt). This also makes the *existing* OTP flow usable end-to-end on Open
WebUI, not just the Google path.

## Live verification checklist (before relying on it)

These cross-container seams are NOT unit-testable; confirm on the stack:

- `docker compose config` parses.
- Open WebUI actually sends `X-OpenWebUI-User-Email` to the bridge — check
  the bridge log for `verified <email> -> <uid>` on a Google-authed chat.
- The `honeybot-auth` volume is writable by both containers (both run as
  UID 10001; the volume seeds from honeybot's pre-created `.hermes/auth`).
  Confirm `verified_sessions.json` appears and both can read it.
- After a Google-authed message, a credentialed skill (e.g. gmail) works
  WITHOUT an OTP prompt; the bridge log shows the verify, and the sidecar
  exists for `openwebui:{uid}`.
- A spoofed/mismatched identity is rejected (bridge logs `identity NOT
  verified`) and that session still gets an OTP prompt — not silent access.

## Security posture

- **Bypasses an identity-verification control**, so the trust boundary is
  load-bearing. The bridge resolves identity from authoritative sources
  (Slack, optionally Open WebUI), never the raw header, and fails closed.
- The bridge is **honeynet-only** (no host port, not via nginx) and
  requires the api_server bearer — a public/unauthenticated bridge that
  trusted an email header would be a trivial identity spoof.
- `establish_trusted_session` is a trusted-issuer bypass; it's only ever
  called from the bridge after round-trip verification, never from
  user-typed input.

## Trust model

- Only trust `X-OpenWebUI-User-Email` because sign-in is **Google-only +
  domain-restricted** (Internal consent screen + `OAUTH_ALLOWED_DOMAINS`).
  If password login is ever re-enabled, that email is no longer
  Google-verified and this trust assumption breaks — revisit before doing
  so.
- The bridge must be reachable **only** from Open WebUI on honeynet, never
  publicly, and must present the api_server bearer. A public bridge that
  accepts an email header would be a trivial identity-spoof.
- `establish_trusted_session` is a trusted-issuer bypass; never call it
  from user-typed input or an unauthenticated path.
