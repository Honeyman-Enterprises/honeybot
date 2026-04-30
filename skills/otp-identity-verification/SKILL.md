---
name: otp-identity-verification
version: 0.1.0
description: OTP-based identity verification for non-Slack interfaces. Proves who the user is before granting access to credentialed services (Gmail, AWS, GitHub, 1Password).
triggers:
  - "verify my identity"
  - "verify me"
  - "otp"
  - "verification code"
  - "identity check"
  - "who am i"
capabilities:
  - otp_generate
  - otp_verify
  - otp_check
  - session_verify
---

# OTP Identity Verification

## Deployment status

**Deployed.** PR #33 merged and the OTP gate is live in `creds.sh` and
`skills/_lib/`. All non-Slack credential access now requires OTP
verification.

`HONEYBOT_OTP_BYPASS=1` exists as an admin/debug escape hatch but should
not be used in normal operation.

## What this solves

Honeybot grants per-user access to external services (Gmail, AWS, GitHub,
HubSpot) by looking up credentials in 1Password keyed on Slack user ID:
`op://Honeybot/{Service}-{SlackUID}/{field}`.

From **Slack**, the user's identity is inherent — the gateway's WebSocket
connection is authenticated by Slack, and the `honeybot-identity` hook
writes the Slack UID to a per-session sidecar file that `creds.sh` reads.

From **non-Slack interfaces** (Open WebUI, Discord, API, etc.), there is
no signed identity assertion. Anyone who can reach the chat interface could
claim to be any user. The OTP flow closes this gap: the user must prove
they control the email address associated with a Slack UID before the bot
will read credentials on their behalf.

## When this triggers

- **Automatically**: `creds.sh` checks the OTP gate before every
  credential read on non-Slack sessions. If unverified, it exits with
  code 4 and a message telling the agent to initiate the OTP flow.
- **Manually**: the user says "verify my identity", "verify me", etc.
- **On first credential access from a new interface/session**: the
  credentialed skill (Gmail, AWS, etc.) will fail with an auth error,
  and the agent should recognize it and start the OTP flow.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  User on Open WebUI / Discord / API                 │
│  "check my gmail"                                   │
└───────────────┬─────────────────────────────────────┘
                ▼
┌─────────────────────────────────────────────────────┐
│  Agent invokes gmail.sh → creds.sh                  │
│  creds.sh calls verify_session.sh                   │
│  → exit 4: "not verified"                           │
└───────────────┬─────────────────────────────────────┘
                ▼
┌─────────────────────────────────────────────────────┐
│  Agent runs OTP flow:                               │
│  1. Ask: "What email is your Honeybot account       │
│     registered under?"                              │
│  2. otp_auth.py generate --email ... --session-key  │
│  3. User checks email, types 6-digit code           │
│  4. otp_auth.py verify --code ... --session-key     │
│  5. ✅ Session verified for 30 days (sliding window) │
└───────────────┬─────────────────────────────────────┘
                ▼
┌─────────────────────────────────────────────────────┐
│  Agent retries creds.sh → gate passes               │
│  → credential read succeeds → gmail.sh works        │
└─────────────────────────────────────────────────────┘
```

## The OTP flow (step by step)

### Step 1: Determine the user's email

Try these shortcuts first:
- If `$HONEYBOT_SLACK_USER` is set (Slack sessions), skip OTP entirely —
  Slack's identity is trusted.
- Ask the user: "What's the email address associated with your Honeybot
  account?" They'll typically know (it's their work email).

Known users (for reference — **don't hardcode**, always verify via OTP):
- Eric Hodonsky → eric.hodonsky@honeymanenterprises.com (Slack UID: U09NS7DSK8U)
- Michelle → michelle@honeymanenterprises.com (Slack UID: U09NS7H5J5S)

### Step 2: Send the OTP

```bash
python3 skills/_lib/otp_auth.py generate \
  --email "USER@EXAMPLE.COM" \
  --session-key "$HERMES_SESSION_KEY" \
  --interface "openwebui" \
  --claimed-uid "SLACK_UID_IF_KNOWN"
```

This:
- Generates a random 6-digit code
- Hashes it (SHA-256) and stores it in `~/.hermes/auth/pending_otps.json`
- Sends it via SMTP (using `skills/_lib/send_email.py`)
- Code expires in **5 minutes**

Tell the user: "I've sent a verification code to your-email@example.com.
Check your inbox and paste the 6-digit code here."

### Step 3: Verify the code

```bash
python3 skills/_lib/otp_auth.py verify \
  --code "123456" \
  --session-key "$HERMES_SESSION_KEY"
```

On success:
- Creates a verified session in `~/.hermes/auth/verified_sessions.json`
- Valid for **30 days** (sliding window — every credential access resets the clock)
- Returns JSON: `{"status": "verified", "email": "...", "slack_uid": "..."}`

On failure:
- Wrong code → "Incorrect code. N attempts remaining." (max 5 attempts)
- Expired → "OTP expired. Request a new code."
- Too many attempts → "Too many failed attempts. Request a new code."

### Step 4: Retry the original request

Once verified, re-run whatever the user originally asked for. `creds.sh`
will now pass the gate.

## Checking auth state (for any script/skill)

```bash
# Shell
python3 skills/_lib/verify_session.py --session-key "$HERMES_SESSION_KEY"
# Exit 0 = verified, exit 4 = not verified

# Or via the shell wrapper
source skills/_lib/verify_session.sh || exit $?
```

```python
# Python
from otp_auth import check_session, get_verified_email

session = check_session(os.environ["HERMES_SESSION_KEY"])
if session:
    print(f"Verified as {session.email} (UID: {session.slack_uid})")
else:
    print("Not verified — initiate OTP flow")
```

## Revoking a session

```bash
python3 skills/_lib/otp_auth.py revoke --session-key "$HERMES_SESSION_KEY"
```

## Session key normalization

The OTP system normalizes session keys so verification persists sensibly:
- **Slack**: `agent:main:slack:dm:CHANNEL:TS` → `slack:CHANNEL` (all
  threads in a DM channel share verification)
- **Non-Slack with UID**: `{interface}:{slack_uid}` (all sessions from
  the same user on the same interface share verification)
- **Fallback**: the raw session key

**Keys must use stable IDs (Slack UIDs), not emails or names.** Email is
only used as the OTP *delivery address*, never as a key component.

This means: verify once on Open WebUI, and you stay verified for 30 days
across all your Open WebUI conversations. Every credential access resets
the 30-day clock — the session only expires if you go 30 days without
touching any credentialed service.

## Security properties

- OTP codes are **never stored in plaintext** — only SHA-256 hashes
- Maximum **5 attempts** per code, then it's burned
- Codes expire in **5 minutes**
- Verified sessions expire in **30 days** (sliding window — refreshed on use)
- `last_used_at` tracked for audit; every successful gate check slides `expires_at` forward
- JSON state files are mode **0600** with file locking
- **Slack sessions bypass OTP entirely** — Slack's signed WebSocket
  provides stronger identity proof than email OTP

## Bypass mechanisms

- `HONEYBOT_OTP_BYPASS=1` in environment — skips the gate entirely.
  For admin/debug/CI use only. Never set this in production.
- Slack DM sessions — automatically bypass (detected by session key
  format containing `:slack:`)

## File layout

```
skills/_lib/
├── otp_auth.py          # Core OTP logic (generate, verify, check, revoke)
├── verify_session.py    # Credential access gate (Python)
├── verify_session.sh    # Shell wrapper for creds.sh integration
├── creds.sh             # Updated: calls verify_session.sh before op read
└── send_email.py        # SMTP sender (already existed, used by OTP)

~/.hermes/auth/          # Runtime state (not in repo)
├── pending_otps.json    # Codes awaiting verification
└── verified_sessions.json  # Verified sessions
```

## Non-Slack session setup (critical)

When running credential-accessing scripts from a non-Slack context (Open
WebUI, Discord, API, manual testing), you MUST set `HERMES_SESSION_KEY` or
`creds.sh` will crash with `unbound variable` (it uses `set -u`).

**Known issue (as of 2026-04-30):** `HERMES_SESSION_KEY` is NOT
automatically injected by the Hermes runtime for non-Slack sessions. The
agent must export it manually before any `creds.sh` call. This is a gap
in the gateway — Slack sessions get `$HONEYBOT_SLACK_USER` injected by
the `honeybot-identity` hook, but non-Slack sessions have no equivalent
for `HERMES_SESSION_KEY`.

**Workaround:** Set it from the user's identity + interface. **Use stable
IDs, not names or emails**, as keys — names and emails can change, IDs
are permanent:
```bash
export HERMES_SESSION_KEY="openwebui:U09NS7DSK8U"
export HONEYBOT_SLACK_USER=U09NS7DSK8U
```

The session key format is `{interface}:{user_id}`, e.g.:
- `openwebui:U09NS7DSK8U` — Eric on Open WebUI (Slack UID as stable ID)
- `discord:U09NS7DSK8U` — Eric on Discord
- `api:U09NS7DSK8U` — API session

**Use Slack UIDs as the universal user identifier** across all interfaces.
Email is only used for *sending* the OTP — never as a session key component.
This ensures session verification persists correctly even if the user's
email address changes.

**IMPORTANT: The session key used for `generate` MUST match the key used
for `verify` and `check`.** If you generate with `openwebui:U09NS7DSK8U`
but `creds.sh` passes a different key, verification won't be found.

**Full invocation pattern for non-Slack sessions:**
```bash
export HERMES_SESSION_KEY="openwebui:U09NS7DSK8U"
export HONEYBOT_SLACK_USER=U09NS7DSK8U

# This will return exit 4 if not OTP-verified:
~/.hermes/skills/gmail/bin/gmail.sh search "is:unread" --max 10

# To verify first:
python3 ~/.hermes/skills/_lib/otp_auth.py generate \
  --email "eric.hodonsky@honeymanenterprises.com" \
  --session-key "$HERMES_SESSION_KEY" \
  --interface "openwebui" \
  --claimed-uid "U09NS7DSK8U"
# User provides the 6-digit code from their email
python3 ~/.hermes/skills/_lib/otp_auth.py verify \
  --code "123456" \
  --session-key "$HERMES_SESSION_KEY"
# Now credential access works for 30 days
```

**Note:** The `creds.sh` error message currently references
`~/.hermes/auth/otp_auth.py` but the actual deployed path is
`~/.hermes/skills/_lib/otp_auth.py`. Use the `skills/_lib/` path — the
error message path is a known bug (queued for fix in next PR).

### Verifying the session actually persisted

After calling `verify`, always confirm `verified_sessions.json` was
created. In this session we discovered a case where verify appeared to
succeed (agent said "Verified!") but the file was never written — the
verify call had actually failed silently due to a session key mismatch.

```bash
cat ~/.hermes/auth/verified_sessions.json
# Should show an entry for your session key with expires_at ~30 days out
```

If the file doesn't exist or is empty after verify, the session key used
for generate didn't match the one used for verify.

## Edge cases

| Situation | Handling |
|-----------|----------|
| User gives wrong email | OTP goes to wrong inbox; they never get the code; they retry with correct email |
| User's email not in 1Password | OTP verifies their identity, but `creds.sh` will still fail at the `op read` step (no vault item for that UID). That's correct — they're authenticated but not authorized. |
| Multiple users, same interface | Each gets their own normalized session key (`{interface}:{slack_uid}`), so verification is per-user |
| Session expires mid-conversation | Next credential access triggers a new OTP flow. 30-day sliding window makes this extremely rare — it only happens if you don't use any credentials for a full month. |
| SMTP not configured | `otp_auth.py` raises RuntimeError, agent should tell user "email verification is not available yet" |

## Guardrails

- **Never** skip the OTP gate for non-Slack credential access (unless
  `HONEYBOT_OTP_BYPASS=1` is set by an admin)
- **Never** reveal the OTP code in chat — it's sent via email only
- **Never** store plaintext OTP codes anywhere
- **Never** extend the session TTL beyond 30 days without explicit
  user/admin approval (the sliding window resets to 30 days on use, never beyond)
- **Always** re-verify if a user claims to be someone different than
  their current verified identity
