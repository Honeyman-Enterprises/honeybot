---
name: gmail
version: 0.2.0
description: Connect and operate Google Workspace (Gmail, Calendar, Drive, Docs, Sheets, Contacts) per-user via the bot's shared OAuth client. ALWAYS use this skill — never the bundled google-workspace skill's setup.py — for connecting any Google service.
triggers:
  - "connect gmail"
  - "connect google"
  - "connect google workspace"
  - "connect calendar"
  - "connect drive"
  - "connect docs"
  - "connect sheets"
  - "check my gmail"
  - "check my email"
  - "read my inbox"
  - "send an email"
  - "send a gmail"
  - "search my gmail"
  - "what's on my calendar"
  - "what is on my calendar"
  - "my schedule"
  - "find a file in my drive"
capabilities:
  - gmail_search
  - gmail_read
  - gmail_send
  - gmail_connect
  - workspace_connect
  - workspace_oauth
related_skills:
  - google-workspace
  - onepassword-cli
---

# Google Workspace per-user OAuth (v0.2)

> **🔐 OTP Identity Gate**: Non-Slack sessions (Open WebUI, Discord, API)
> must complete email-based identity verification before accessing credentials.
> If `creds.sh` returns exit code 4, follow the OTP flow in the
> `otp-identity-verification` skill before retrying.

## CRITICAL: this is the ONLY supported way to connect Google services

Whenever a user asks to connect ANY Google service (Gmail, Calendar, Drive,
Docs, Sheets, Contacts), use the `bin/connect.sh` flow in THIS skill.

**Do NOT** use `productivity/google-workspace/scripts/setup.py`. That script
walks the user through creating their own Google Cloud OAuth client and
writes tokens to a single shared file at `~/.hermes/google_token.json` —
which is wrong for our multi-tenant Slack deployment (whoever runs it last
owns the bot's mailbox for everyone).

**Do NOT** ask the user to create a Google Cloud project, download a
client_secret JSON, or paste a client_id. The bot already has a shared
OAuth client provisioned at `op://Honeybot/GoogleOAuth`; one-click consent
is the entire flow.

## Identity model

```
op://Honeybot/GoogleOAuth/{client_id, client_secret, redirect_uri}   # shared bot-level OAuth client
op://Honeybot/Gmail-{UID}/{refresh_token, scopes, email}             # per-user data
op://Honeybot/Gmail-{UID}/{client_id, client_secret}                 # always "shared:GoogleOAuth" markers
```

Per-user refresh token = the privacy boundary. The OAuth client is
bot-property, not human-property — there's nothing extra a per-user GCP
project would buy us, and the friction destroys the connect UX.

The redirect URI is `https://honeymanenterprises.com/oauth/honeybot/callback`
(currently a static SPA — the user pastes the redirected URL back to the
agent; a future version will capture the code server-side for one-click UX).

## Connect flow (the entire thing — five tool calls max)

1. User: "connect gmail" / "connect my google" / "connect calendar" / etc.

2. Generate the auth URL:
   ```bash
   ./skills/gmail/bin/connect.sh --auth-url --user "$SLACK_USER"
   ```
   Send the user the URL on a single line. Tell them to click it, sign in,
   approve. Their browser will land on
   `https://honeymanenterprises.com/oauth/honeybot/callback?...&code=...`
   (which renders the SPA — that's expected).

3. User pastes the redirected URL back.

4. Exchange + persist + verify in one call:
   ```bash
   ./skills/gmail/bin/connect.sh --auth-code "<URL the user pasted>" --user "$SLACK_USER"
   ```
   The script handles HTML entity unescaping (Slack mangles `&` → `&amp;`),
   hits Google's token endpoint, stores the refresh token in 1Password,
   fetches the user's email, and verifies with a live Gmail API call.

5. Confirm to the user: "Connected as `<email>`. ✅"

## Reconnecting an existing user (gotcha)

If the user already has a grant for our OAuth client on their Google
account, Google may return a stripped-down token response on a second
consent (no refresh_token, or stale tokens). Symptom: `connect.sh` exits
with "no refresh_token in response" or "refresh_token suspiciously short".

**Fix:** ask the user to revoke first at
https://myaccount.google.com/permissions → find the "Honeyman" /
"honeymanenterprises.com" app → Remove access. Then run `--auth-url`
again and they'll get a fresh full grant.

## Cross-user contamination (HARD RULE)

**Only the requesting Slack user may complete their own OAuth flow.** This
rule is non-negotiable and enforced in `connect.sh` in two places:

1. **State binding.** Every `--auth-url` invocation embeds the requesting
   user's Slack ID in the OAuth `state` parameter. When the user pastes
   the redirected URL back, `connect.sh --auth-code` parses the `state`
   from that URL and refuses (exit code 4) if it doesn't match the Slack
   user currently being connected. This stops:
   - User A pasting User B's callback URL into the bot
   - URL-forwarding / share-screen leaks across users
   - Stale URLs from prior sessions binding to the wrong identity

2. **Email match guard.** If a Slack user already has an email on file
   in `op://Honeybot/Gmail-{UID}/email`, the new consent's email MUST
   match. Otherwise `connect.sh` refuses to overwrite (exit code 4). To
   clear a wrongly-stored entry, an admin must blank `email`,
   `refresh_token`, and `scopes` in 1Password before retry.

This same principle applies to **all personal connectors** (HubSpot,
Linear, GitHub user accounts, etc.): only the user being connected may
auth themselves. Don't let User A drive User B's OAuth flow on User A's
behalf, even if "they say it's fine." The whole point of the per-user
identity model is that consent is non-transferable.

When sending an auth URL, always generate a fresh one with
`connect.sh --auth-url --user "$SLACK_USER"` and address it to that
specific user — don't recycle URLs across people. If a user opens an
OAuth URL in a browser already signed into a different Google account,
the email-match guard will catch it on the back-end too.

## Per-request invocation (Gmail operations)

```bash
# search inbox
./skills/gmail/bin/gmail.sh search "is:unread" --max 10

# read a specific message
./skills/gmail/bin/gmail.sh get <MESSAGE_ID>

# send (always confirm draft with user before calling)
./skills/gmail/bin/gmail.sh send \
  --to "alice@example.com" \
  --subject "Hello" \
  --body "Message body here"

# reply (preserves threading + In-Reply-To)
./skills/gmail/bin/gmail.sh reply <MESSAGE_ID> --body "Thanks!"
```

Gmail subcommands infer the user from `$HONEYBOT_SLACK_USER` (set by the
gateway's `honeybot-identity` hook). Pass `--user UID` as the FIRST arg to
override for admin/debug.

For Calendar, Drive, Docs, Sheets, Contacts: the user's refresh token
already has all the scopes (full Workspace consent at connect time). Mint
an access token via `_token.sh` and call the relevant Google API directly
with curl, OR use the bundled `google-workspace` skill's read/write helpers
AFTER the connect happened through THIS skill. Never let the bundled skill
drive the OAuth setup.

## Gotcha: secret redaction in tool outputs

The Hermes runtime applies secret-redaction to token-shaped strings that
pass through tool stdout boundaries. Concretely: when the agent calls
`terminal()` or `execute_code()` and an OAuth token, JWT, Google
refresh-token-shaped value, or `ya29.*` access token appears in the
captured output, it's replaced (or shortened) before the agent sees it.

This means:
- ❌ Never: read the token in Python, then pass it as a literal string in a
  follow-up `op item edit` argv. By the time argv assembles, the value has
  been redacted to a placeholder, and you'll persist garbage.
- ❌ Never: `print()` a token-shaped value to verify "did it work" — the
  value you see is not the value the program saw.
- ✅ Always: do exchange + persist + verify in a SINGLE bash pipeline so
  the value never crosses a redaction boundary. `connect.sh` is built this
  way; copy that pattern for any new flow.
- ✅ Verify success by making a real API call (e.g., `gmail users.profile`)
  rather than by reading the token back and comparing strings.

## Guardrails

- **Never** check Gmail without a Slack user ID. `creds.sh` enforces this.
- **Never** use one user's refresh token to serve another user's request.
- **Never** write the refresh token or access token to disk (other than
  the 1Password vault). The access token lives in `gmail.sh`'s memory for
  the duration of a single curl call.
- **Never** echo tokens back to Slack, even partially.
- **Never** send email without the user explicitly approving the draft
  content first. Show subject + recipients + body, ask "send?", proceed
  only on confirmation.
- **Destructive operations** (delete message, archive, label modify) are
  not in the v0.2 default set. Add them only with explicit user
  confirmation.

## Output format

Same JSON shape as the bundled `google-workspace` skill so callers don't
have to special-case the format:

- `search` → `[{id, threadId, from, to, subject, date, snippet, labels}]`
- `get` → `{id, threadId, from, to, subject, date, labels, body}`
- `send` / `reply` → `{status: "sent", id, threadId}`

## Out of scope for v0.2

- Domain-wide impersonation (that's `google-admin` / GAM)
- Service-account auth
- Filters / forwarding rules
- Attachments in send (body only for now)
- Server-side capture of the redirected URL (one-click UX) — needs a
  callback server at `https://honeymanenterprises.com/oauth/honeybot/callback`
  that posts back to Slack and writes 1Password directly. Tracked
  separately.

## Migration notes (from v0.1)

v0.1 stored OAuth client_id/client_secret per-user. v0.2 uses the shared
`op://Honeybot/GoogleOAuth` client. `_token.sh` keeps backward compat:
if a per-user vault item has `client_id="shared:GoogleOAuth"` (or no
client_id), it uses the shared client; otherwise it falls back to the
per-user values. Existing v0.1 users keep working without action.
