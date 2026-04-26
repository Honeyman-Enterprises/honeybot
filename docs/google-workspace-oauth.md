# Google Workspace OAuth — shared bot-wide client + per-user tokens

Status: shipped April 2026. This doc is the canonical reference for how
Google Workspace connections (Gmail, Calendar, Drive, Docs, Sheets,
Contacts) work in Honeybot's multi-tenant Slack deployment.

## TL;DR

- One bot-wide OAuth client at `op://Honeybot/GoogleOAuth`. Every Slack
  user shares it. No per-user GCP project — that flow is dead.
- Each Slack user's refresh token lives at `op://Honeybot/Gmail-{UID}/`.
  That's the privacy boundary.
- The `gmail` skill (`skills/gmail/`) owns the entire connect flow for
  ALL Google services. The bundled `productivity/google-workspace`
  skill's `setup.py` is a privacy bug in this deployment and is not
  used.
- HARD RULE: only the requesting Slack user may complete their own
  OAuth. Enforced via OAuth `state=$SLACK_USER` and an email-match
  guard on retries. See `skills/gmail/SKILL.md` for the full rule.

## Vault layout

| Path                                                | Kind    | Purpose                                          |
|-----------------------------------------------------|---------|--------------------------------------------------|
| `op://Honeybot/GoogleOAuth/client_id`               | shared  | Desktop OAuth client ID (one for all users)      |
| `op://Honeybot/GoogleOAuth/client_secret`           | shared  | Desktop OAuth client secret                      |
| `op://Honeybot/GoogleOAuth/redirect_uri`            | shared  | `https://honeymanenterprises.com/oauth/honeybot/callback` |
| `op://Honeybot/Gmail-{SlackUID}/refresh_token`      | per-user| Long-lived refresh token (full Workspace scopes) |
| `op://Honeybot/Gmail-{SlackUID}/scopes`             | per-user| Space-separated granted scopes                   |
| `op://Honeybot/Gmail-{SlackUID}/email`              | per-user| The Google account email (also identity guard)   |
| `op://Honeybot/Gmail-{SlackUID}/client_id`          | marker  | Always `shared:GoogleOAuth` (sentinel value)     |
| `op://Honeybot/Gmail-{SlackUID}/client_secret`      | marker  | Always `shared:GoogleOAuth` (sentinel value)     |

The marker fields tell `_token.sh` to use the shared OAuth client.
Legacy v0.1 entries (with real per-user `client_id`/`client_secret`
values) are still honored — `_token.sh` falls back to the per-user
values when the marker is absent.

## Connect flow

```bash
# 1. Generate auth URL (state binds to the Slack user)
~/.hermes/skills/gmail/bin/connect.sh --auth-url --user "$SLACK_USER"

# 2. After user pastes redirect URL back:
~/.hermes/skills/gmail/bin/connect.sh --auth-code "<URL>" --user "$SLACK_USER"
```

The script:
- Parses `state=` from the redirect URL and refuses if it doesn't match
  `$SLACK_USER` (cross-user contamination guard)
- Exchanges code for tokens entirely inside one bash pipeline (avoids
  the secret-redaction tooling boundary that mangles token-shaped
  strings — see `skills/gmail/SKILL.md` § "Gotcha")
- Looks up the Google account email and refuses to overwrite if a
  different email is already on file (email-match guard)
- Verifies success with a live Gmail API call before exiting

## Deployment-local pieces (NOT in this repo)

These changes were made on the running host but live outside the repo
because they're either Hermes core overlays or per-deployment config.
They are listed here so future operators don't recreate the bug.

### 1. `~/.hermes/skills/productivity/google-workspace/SKILL.md` (Hermes core overlay)

Top of file replaced with a banner that redirects all OAuth setup to
the `gmail` skill. The legacy single-user setup flow is marked
DEPRECATED. Original preserved at
`~/.hermes/_archive/2026-04-26-shared-google-removal/`.

### 2. `~/.hermes/skills/productivity/google-workspace/scripts/setup.py`

Replaced with a stub that prints a pointer to the `gmail` skill and
exits 2. Original preserved at
`~/.hermes/_archive/2026-04-26-shared-google-removal/setup.py.original`.

This was the privacy bug: the original wrote a single shared
`~/.hermes/google_token.json` file. Whoever ran it last owned the
bot's Google identity for everyone.

### 3. `~/.hermes/google_token.json` and `~/.hermes/google_client_secret.json`

Removed (archived). If they reappear, something ran the legacy
setup.py — investigate and re-disable.

### 4. `~/.hermes/config.yaml` — Slack tool-call display silencing

```yaml
display:
  platforms:
    slack:
      tool_progress: off
      tool_preview_length: 0
```

Stops the bot from posting tool-use chatter into Slack messages.
Telegram and other platforms are unaffected.

## Migration notes (v0.1 → v0.2)

v0.1 stored the OAuth client per-user (one GCP project per human).
v0.2 uses the shared bot-wide client. Existing v0.1 users keep working
without any action — `_token.sh` detects the per-user `client_id`/
`client_secret` values and uses them. To migrate a v0.1 user to v0.2,
overwrite both per-user fields with `shared:GoogleOAuth` and they'll
start using the shared client on next token mint.

## Out of scope (followups)

- **Server-side capture of the redirect URL.** Today the user pastes
  the redirected URL back into Slack — works but is awkward. A future
  callback handler at `https://honeymanenterprises.com/oauth/honeybot/callback`
  would capture the code server-side, complete the exchange, write to
  1Password, and post the result back to Slack as the bot. That's
  blocked on standing up the callback service.
- **Slack target resolver bug.** `send_message(target='slack:D...')`
  fails because `_parse_target_ref` in `tools/send_message_tool.py`
  has no Slack-specific branch (only Telegram, Discord, Feishu,
  WeiXin, phone). Slack channel/DM IDs (start with `C`/`D`/`G`) fall
  through to channel-name resolution and 404. Tracked separately.
- **Apply the same identity model to other personal connectors.**
  HubSpot, Linear, GitHub user accounts, etc. all need the same
  OAuth-state binding + email-match pattern. Not yet ported.
