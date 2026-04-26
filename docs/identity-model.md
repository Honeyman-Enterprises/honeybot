# Honeybot Identity Model

**Audience:** future-Eric, future-contributors. Read this before adding any skill
that touches a user-scoped external service (Gmail, AWS, HubSpot, Calendar).

## The one rule

> Every credential that represents a human is stored at
> `op://Honeybot/{Service}-{SlackUserID}/{field}` and is only ever read using
> the Slack user ID of the person who sent the message we are currently
> responding to.

If Eric (`U04ERIC`) asks the bot "what's in my inbox", the Gmail skill reads
`op://Honeybot/Gmail-U04ERIC/refresh_token`. If Michelle (`U05MICHELLE`) asks
the same thing two seconds later in a different DM, the skill reads
`op://Honeybot/Gmail-U05MICHELLE/refresh_token`. The skill never chooses which
user — it inherits the user from the request.

This is the entire multi-tenant model. No groups, no roles, no RBAC engine.
The vault path _is_ the ACL.

## Vault item naming

| Service          | Item name pattern           | Fields                                                       |
|------------------|-----------------------------|--------------------------------------------------------------|
| Gmail / Calendar | `Gmail-{UID}`               | `refresh_token`, `client_id`, `client_secret`, `scopes`      |
| AWS (per user)   | `AWS-{UID}`                 | `access_key_id`, `secret_access_key`, `default_region`       |
| HubSpot          | `HubSpot-{UID}`             | `personal_access_key`, `portal_id`                           |
| Slack (per user) | `Slack-{UID}`               | `user_token` (`xoxp-...`)                                    |

### Shared / bot-level items (no `-UID` suffix)

These represent the bot itself or domain-wide delegation, not a human:

| Item                         | Purpose                                                      |
|------------------------------|--------------------------------------------------------------|
| `Anthropic API`              | The bot's Claude key                                         |
| `Slack Bot`                  | Bot token, app token, signing secret, allow-listed users     |
| `GoogleWorkspace Admin`      | Service account JSON for GAM domain-wide ops                 |
| `AWS Bot` (optional, future) | Bot-owned IAM creds for AWS ops the bot does on its own      |

GAM (Google Workspace admin CLI) is a special case: it impersonates any domain
user via a service account, so it lives at the bot level, not per-user. Guard
it behind a small allow-list of Slack user IDs permitted to do admin things.

## How the Slack user ID reaches a skill

Hermes already knows who sent the message — it has to, in order to enforce
`SLACK_ALLOWED_USERS`. The gateway exposes that ID inside the agent process
via `gateway.session_context.HERMES_SESSION_USER_ID` (a `ContextVar`,
task-local across asyncio tasks). But ContextVars do not propagate to
child processes, and shell skills run as subprocesses that inherit
`os.environ`, not contextvars.

Setting `os.environ["HONEYBOT_SLACK_USER"]` from a per-message handler
would race under concurrent traffic from different users (the exact bug
that motivated the contextvars rewrite in the first place — see
`gateway/session_context.py`).

We bridge the gap with a **per-session sidecar file** populated by a
gateway hook:

1. The gateway emits `agent:start` with `context["user_id"]` set to the
   requesting Slack user's ID (see `gateway/run.py`).
2. Our hook at `hooks/honeybot-identity/handler.py` (shipped to
   `~/.hermes/hooks/honeybot-identity/` by the Dockerfile) catches that
   event and writes the ID to:

   ```
   /tmp/honeybot-identity/{session_key_safe}/HONEYBOT_SLACK_USER
   ```

   where `session_key_safe` is `$HERMES_SESSION_KEY` with `:` and `/`
   replaced by `_`. Each session gets its own directory, which is
   concurrency-safe because two messages in the same session are
   serialized by the gateway anyway.

3. `skills/_lib/creds.sh` resolves the user ID with this precedence:

   1. `--user UID` (explicit override, used by admin/debug scripts)
   2. `$HONEYBOT_SLACK_USER` (CLI / local-dev override, set in `op.env`)
   3. The sidecar file, found via `$HERMES_SESSION_KEY` (which IS in
      subprocess env by the time tools run — Hermes sets
      `os.environ["HERMES_SESSION_KEY"]` inside `run_sync` before tool
      execution; see `gateway/run.py`)

### Reading the session key inside the gateway hook

`HERMES_SESSION_KEY` exists in two places at different points in the
message lifecycle:

| When | ContextVar (in-process) | `os.environ` (subprocesses) |
| --- | --- | --- |
| Before `agent:start` emit | ✅ set by `_set_session_env` | ❌ not yet set |
| Inside skill subprocesses | n/a | ✅ set by `run_sync` |

The gateway hook fires at `agent:start`, **before** Hermes writes the
env var. Hooks that need the session key must read it via
`gateway.session_context.get_session_env("HERMES_SESSION_KEY")`, which
checks the contextvar first and falls back to `os.environ` (for CLI/cron
contexts that bypass the gateway). Reading `os.environ` directly from a
hook produced the long-running "agent:start fired without
HERMES_SESSION_KEY in env" warning and broke the sidecar pipeline.

Skill subprocesses have it easier — they can just read
`$HERMES_SESSION_KEY` from the environment, which is what
`skills/_lib/creds.sh` does today.

If none of those resolve to a valid Slack UID, `creds.sh` refuses to read
the vault. Fail-closed, no defaults, no fallback to "the last user".

Skills **MUST** continue to refuse to run without a user ID. The hook is
an enabler, not an escape hatch — its absence (e.g. on a CLI install
without `~/.hermes/hooks/honeybot-identity/`) means per-user skills are
unusable, which is the correct safe state for a multi-tenant deployment
that's missing its identity wiring.

## OAuth for per-user Google / AWS (no inbound port)

Services that authenticate real humans use OAuth 2.0 with the user's own
Google Cloud OAuth client. Two flows are valid; pick whichever the skill
implements.

### Flow A — Device Authorization Grant (RFC 8628), preferred long-term

Same flow as `gh auth login`, `aws sso login`, and "plug TV into Netflix":

1. User DMs: `connect gmail`
2. Bot hits Google's device-authz endpoint → gets `device_code`, `user_code`,
   `verification_url`, `interval`, `expires_in`.
3. Bot DMs back:
   > Open https://google.com/device on any phone/laptop and enter code
   > `WDJB-MJHT`. I'll finish hooking things up once you approve.
4. Bot polls the token endpoint every `interval` seconds with the
   `device_code` until Google returns `access_token` + `refresh_token` (or
   errors out).
5. Bot writes `refresh_token` to `op://Honeybot/Gmail-{UID}/refresh_token`.
   The short-lived access token is never stored — refreshed on demand.

No callback URL, no port forwarding, no ngrok. Requires the user to enable
"TVs and Limited Input devices" client type in their Google Cloud project.

### Flow B — Loopback redirect (Desktop OAuth client), used by v0.1 `gmail` skill

Reuses the standard Desktop OAuth client type that everyone already has from
the `google-workspace` setup:

1. User DMs: `connect gmail`
2. Bot generates an auth URL pointing at `redirect_uri=http://localhost:1`,
   DMs it.
3. User opens URL → Google consent screen → approves → browser redirects
   to `http://localhost:1/?code=4/0A...` and shows a connection-refused
   page. That's expected: there is no local server.
4. User pastes the entire failed-load URL back into Slack DM.
5. Bot extracts `?code=` and exchanges it server-side at
   `https://oauth2.googleapis.com/token` for `access_token` + `refresh_token`.
6. Bot writes `refresh_token` to `op://Honeybot/Gmail-{UID}/refresh_token`.

Slightly more user steps than Flow A (one paste-back), but doesn't require
the user to set up a second Google Cloud client type. v0.2 can migrate to
Flow A once we want to optimize the connect UX.

### Scope hygiene

Request the minimum Google scopes per skill. `gmail.readonly` is a different
consent than `gmail.modify`. Store the granted scope list in the vault item
(`scopes` field) so skills can assert "I need `gmail.send` but this token
only has `gmail.readonly`" and re-prompt.

## AWS per-user: start simple

**v1 (now):** each user generates a personal IAM access key pair, DMs it to
the bot, bot writes to `op://Honeybot/AWS-{UID}/{access_key_id,secret_access_key}`.
Skills set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in subprocess env
only, never on disk.

**v2 (when we outgrow v1):** AWS IAM Identity Center (formerly SSO) with
device flow (`aws sso login --use-device-code`). Same UX, better security
posture, no long-lived keys.

Don't build v2 first.

## Slack CLI — deferred

Installed in the image so it's there when we want it, but v1 skills don't
need per-user Slack identities because the bot itself already has
workspace-level Slack creds. Revisit if a user wants the bot to perform
actions that require _their_ Slack identity (e.g. reacting as them, sending
as them). Pattern is the same: `Slack-{UID}` with a `xoxp-` user token.

## Failure modes we explicitly accept

- **Missing vault item.** User hasn't connected that service yet. Skill says
  "you haven't connected Gmail — want me to start the setup?" and suggests
  the connect command. No silent fallback.
- **Expired refresh token.** Google rotated it or revoked. Skill catches
  `invalid_grant`, tells user, runs the connect flow again.
- **Scope insufficient.** Skill needs `gmail.send`, token only has
  `gmail.readonly`. Refuse, re-prompt consent.
- **Slack user ID absent from request.** Hard error, no work done. Something
  upstream is broken and we do not guess.

## Failure modes we explicitly refuse to engineer around

- Spoofed Slack user IDs. `SLACK_ALLOWED_USERS` is the gate. Anyone not on
  that list cannot reach a skill at all. Within the allow-list we trust the
  incoming user ID from the Slack event, which is signed by Slack's WebSocket
  handshake.
- Cross-user "admin overrides". If admin-level access is needed (read
  someone else's mail as a workspace admin), that's GAM + service account,
  and it's a separate skill with its own allow-list. Never a flag on a
  user-scoped skill.
