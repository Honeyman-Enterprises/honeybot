---
name: gmail
version: 0.1.0
description: Read and send Gmail on behalf of the requesting Slack user, using their personal OAuth refresh token from 1Password. Per-user only — never falls back to a shared mailbox.
triggers:
  - "check my gmail"
  - "check my email"
  - "read my inbox"
  - "send an email"
  - "send a gmail"
  - "search my gmail"
  - "connect gmail"
capabilities:
  - gmail_search
  - gmail_read
  - gmail_send
  - gmail_connect
related_skills:
  - google-workspace
  - onepassword-cli
---

# Gmail Skill — per-user Gmail (v0.1)

## Why this skill exists

The bundled `google-workspace` skill (in Hermes core) stores a single OAuth
token at `~/.hermes/google_token.json`. That works for a single-user CLI
install, but in our multi-tenant Slack deployment it means whoever ran
`setup.py` first owns the mailbox the bot sees — every other Slack user who
asks "check my Gmail" gets that person's inbox. That is a privacy bug.

This skill replaces the Gmail surface of `google-workspace` with a strictly
per-user implementation that follows the project's identity model
(`docs/identity-model.md`):

> Every credential that represents a human is stored at
> `op://Honeybot/{Service}-{SlackUserID}/{field}` and is only ever read
> using the Slack user ID of the person who sent the message we are
> currently responding to.

When this skill is available, **prefer it over `google-workspace` for any
Gmail operation**. The bundled skill is still the right call for Calendar,
Drive, Sheets, Docs, and Contacts until they get the same treatment.

## Identity model

Strictly per-user. Reads the requester's OAuth refresh token from
`op://Honeybot/Gmail-{SlackUserID}/refresh_token`, exchanges it for a
short-lived access token at request time, then makes the Gmail API call.
The access token never touches disk. The refresh token never leaves the
vault.

If the requester has not connected Gmail yet, the skill offers the connect
flow — it does **not** fall back to any default mailbox.

## Vault layout

```
op://Honeybot/Gmail-{UID}/refresh_token    # long-lived OAuth refresh token
op://Honeybot/Gmail-{UID}/client_id        # the user's Google OAuth client_id
op://Honeybot/Gmail-{UID}/client_secret    # the user's Google OAuth client_secret
op://Honeybot/Gmail-{UID}/scopes           # space-separated granted scopes
op://Honeybot/Gmail-{UID}/email            # the user's gmail address (for display)
```

`client_id` and `client_secret` are stored per-user (not bot-level) so each
person can use their own Google Cloud project, and so revoking one user's
OAuth client doesn't blast everyone else.

If you'd rather everyone share a single Google Cloud OAuth client, store
`client_id` / `client_secret` once at `op://Honeybot/Gmail-Bot/` and modify
`bin/_token.sh` to fall back there when the per-user fields are missing.
We are NOT doing that in v0.1 — keep the model simple.

## Connect flow (first-time setup, per user)

The user DMs the bot: `connect gmail`.

The bot walks them through:

1. **Create a Google Cloud OAuth client** (one-time, ~5 min):
   - https://console.cloud.google.com/apis/credentials
   - Create Credentials → OAuth 2.0 Client ID → Application type: **Desktop app**
   - Enable Gmail API in the same project's API Library
   - Download the JSON file
2. **Paste the `client_id` and `client_secret`** into Slack DM (two lines).
   The bot creates the vault item:
   ```bash
   op item create --vault Honeybot \
     --category=login \
     --title="Gmail-${SLACK_USER}" \
     client_id="$CID" client_secret="$CSEC" email="$EMAIL"
   ```
3. **Get an authorization URL** by running:
   ```bash
   ./bin/connect.sh --auth-url --user "$SLACK_USER"
   ```
   The bot DMs the URL to the user.
4. **User opens the URL**, signs in to their Google account, approves the
   scopes. The browser redirects to `http://localhost:1/?code=4/0A...` and
   shows a connection-refused page (expected — there is no local server).
5. **User pastes the entire redirected URL** back into Slack DM.
6. The bot exchanges the code for a refresh token:
   ```bash
   ./bin/connect.sh --auth-code "<URL>" --user "$SLACK_USER"
   ```
   This stores the `refresh_token` and `scopes` fields in the vault item.
7. **Verify**: `./bin/gmail.sh --user "$SLACK_USER" search "in:inbox" --max 1`
   should return one message. Bot reports the address back to the user.

## Per-request invocation pattern

Every Gmail call MUST follow this pattern. The agent never reads the
refresh token directly — `gmail.sh` does that and wipes it from env after
minting the access token.

```bash
# search inbox
./skills/gmail/bin/gmail.sh search "is:unread" --max 10

# read a specific message
./skills/gmail/bin/gmail.sh get <MESSAGE_ID>

# send a message (the agent MUST confirm with the user before calling this)
./skills/gmail/bin/gmail.sh send \
  --to "alice@example.com" \
  --subject "Hello" \
  --body "Message body here"

# reply (preserves threading + In-Reply-To)
./skills/gmail/bin/gmail.sh reply <MESSAGE_ID> --body "Thanks!"
```

`gmail.sh` infers the user from `$HONEYBOT_SLACK_USER`. To override (for
admin/debug only) pass `--user <UID>` as the FIRST arg.

`gmail.sh` returns JSON on stdout. Errors go to stderr with non-zero exit.

## How `$HONEYBOT_SLACK_USER` reaches the skill

In production (gateway/Slack), the requesting user's Slack ID is captured
per-message by the `honeybot-identity` hook
(`hooks/honeybot-identity/handler.py`) on the gateway's `agent:start`
event, and written to a per-session sidecar file. `creds.sh` resolves
the user ID by reading that file, keyed on `$HERMES_SESSION_KEY` (which
IS exported into subprocess env by the gateway). See
`docs/identity-model.md` § "How the Slack user ID reaches a skill" for
the full data flow.

For CLI / local-dev / tests, set `HONEYBOT_SLACK_USER` in `op.env` (or
your shell) and `creds.sh` will use it directly. To override for
admin/debug, pass `--user <UID>` as the FIRST arg to `gmail.sh`. Without
any of these resolving to a valid Slack UID, every skill in this
directory fails closed — that's the intended behavior.

## Guardrails

- **Never** check Gmail without a Slack user ID. `creds.sh` enforces this;
  `gmail.sh` does too.
- **Never** use one user's refresh token to serve another user's request.
- **Never** write the refresh token or access token to disk. The access
  token lives in `gmail.sh`'s memory for the duration of a single curl
  call; the refresh token never leaves stdout from `op read`.
- **Never** echo tokens back to Slack, even partially.
- **Never** send email without the user explicitly approving the draft
  content first. Show subject + recipients + body, ask "send?", proceed
  only on confirmation.
- **Destructive operations** (delete message, archive, label modify) are
  out of scope for v0.1. Add them only with explicit user-confirmation
  prompts.

## Output format

Same JSON shape as the bundled `google-workspace` skill so callers don't
have to special-case the format:

- `search` → `[{id, threadId, from, to, subject, date, snippet, labels}]`
- `get` → `{id, threadId, from, to, subject, date, labels, body}`
- `send` / `reply` → `{status: "sent", id, threadId}`

## Out of scope for v0.1

- Calendar / Drive / Sheets / Docs / Contacts (use bundled `google-workspace`)
- Domain-wide impersonation (that's `google-admin` / GAM)
- Service-account auth
- Label management
- Filters / forwarding rules
- Attachments in send (body only for now)
