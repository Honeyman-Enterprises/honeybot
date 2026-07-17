# owui-auth-bridge

Reverse proxy between Open WebUI and honeybot's api_server that lets a
Google-authenticated Open WebUI session skip the OTP identity gate — by
**round-trip-verifying** the user (not trusting the forwarded header) and
minting a trusted honeybot session. Full design + threat model:
[`docs/openwebui-google-identity.md`](../docs/openwebui-google-identity.md).

## Request flow

```
Open WebUI ──(OpenAI API + X-OpenWebUI-User-* headers)──► owui-auth-bridge ──► honeybot:8642
                                                             │
                     1. require api_server bearer            │
                     2. strip any client X-Hermes-Session-Key │
                     3. verify identity (round-trip):         │
                          email → Slack users.lookupByEmail → UID
                          + active/human + email/domain match
                          + optional Open WebUI (user_id,email) cross-check
                     4. mint trusted session (shared honeybot-auth volume)
                     5. inject X-Hermes-Session-Key: openwebui:{uid}
                     fail closed → forward with NO session key (OTP fallback)
```

## Why round-trip, not inbound filtering

The forwarded `X-OpenWebUI-User-*` headers are a *claim*. We never mint
against the claimed UID; we resolve the UID from **Slack** (authoritative)
using only the claimed email, confirm the account is active/human and the
email/domain match, and optionally confirm the `(user_id, email)` pair
against Open WebUI's own DB. Any mismatch → not verified. See
`bridge/verify.py` and its tests (`tests/test_verify.py`, 12/12).

## Layout

```
bridge/
  verify.py    round-trip verification (pure logic; unit-tested)
  lookups.py   the real HTTP lookups (Slack, optional Open WebUI)
  mint.py      reuse honeybot otp_auth.establish_trusted_session
  app.py       aiohttp proxy: gate → verify → mint → inject → forward
  config.py    env config
_lib/otp_auth.py   COPY'd from skills/_lib at build (single source of truth)
```

## Config (env)

| Var | Source | Notes |
|---|---|---|
| `API_SERVER_KEY` | `.env.runtime` | required inbound bearer (= HermesAPI key) |
| `SLACK_BOT_TOKEN` | `.env.runtime` | needs `users:read.email` scope |
| `UPSTREAM_URL` | compose | `http://honeybot:8642` |
| `OAUTH_ALLOWED_DOMAINS` | compose | `honeymanenterprises.com` |
| `HONEYBOT_AUTH_DIR` | compose | `/auth` (shared honeybot-auth volume) |
| `OWUI_API_URL` / `OWUI_API_KEY` | optional | enable the OWUI cross-check |
| `BRIDGE_REQUIRE_OWUI` | optional | `true` = OWUI check mandatory |

## Test

```bash
python3 tests/test_verify.py      # 12/12, stdlib only
```
