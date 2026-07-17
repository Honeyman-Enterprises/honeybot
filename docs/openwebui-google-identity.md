# Google login → skip OTP (identity synergy)

**Status: partially built.** The reusable, testable primitives + the two
Open WebUI toggles are in. The last-mile bridge is specified here but NOT
built, on purpose — see "Why the last mile is deliberately unbuilt".

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

## The last mile (specified, not built)

A tiny **auth bridge** sits between Open WebUI and the api_server
(Open WebUI points its OpenAI connection at the bridge instead of
`honeybot:8642`). Per request it:

1. Reads `X-OpenWebUI-User-Email` (trustworthy: login is Google-only +
   domain-restricted, so this is a Google-verified Workspace email).
2. Resolves it to a Slack UID (`slack_uid_for_email`).
3. Mints a trusted session for `openwebui:{slack_uid}`
   (`establish_trusted_session`) — writing to honeybot's auth store.
4. Injects `X-Hermes-Session-Key: openwebui:{slack_uid}` and forwards to
   `honeybot:8642`.

Plus a small **`creds.sh`** change: for non-Slack sessions, when no
`user_id` came from `--user` / `$HONEYBOT_SLACK_USER` / the Slack sidecar,
derive it from the verified session (`get_verified_uid`). Without this,
even an OTP- or trust-verified Open WebUI session still can't read creds
because `creds.sh` has no Slack UID to build the vault path. (This is an
independent fix — it also makes the *existing* OTP flow usable without the
agent hand-passing `--user`.)

Then: Google login → bridge mints the trusted session + sets the session
key → `creds.sh` finds the verified session AND derives the UID → per-user
creds resolve, no OTP prompt.

## Why the last mile is deliberately unbuilt

This feature **bypasses an identity-verification control** — the thing that
stops one user's session from reading another user's credentials. Getting
the bridge's trust boundary subtly wrong (e.g. trusting a spoofable header,
or minting for the wrong UID) re-opens exactly the cross-user
credential-read hole the OTP gate closes. That's 🔴 security-critical, and
it spans containers (Open WebUI → bridge → api_server → agent → creds.sh)
with integration seams that can't be unit-tested from the repo. So the
bridge + the `creds.sh` change get built and **verified end-to-end on the
running stack** as their own focused step — not shipped blind alongside
everything else.

Concretely, before building the bridge, confirm on the running stack:
- Open WebUI actually sends `X-OpenWebUI-User-Email` to its OpenAI
  connection target (capture it at the bridge).
- The api_server honors `X-Hermes-Session-Key` from the bridge and the
  agent's `HERMES_SESSION_KEY` / `creds.sh` see `openwebui:{slack_uid}`.
- The auth store is shared correctly between the bridge and honeybot (a
  shared volume, or the bridge calls a honeybot mint endpoint).

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
