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
`SLACK_ALLOWED_USERS`. We surface that ID to skill subprocesses via:

1. **Env var** (preferred): `HONEYBOT_SLACK_USER` set by a thin Hermes adapter
   patch or wrapper, OR by the agent's system prompt instructing the LLM to
   export it before shelling out.
2. **Positional arg**: skills accept `--user $UID` as their first flag.

Skills **MUST** refuse to run without a user ID. No default, no fallback to
"the last user", no env-level `DEFAULT_USER`. Missing ID = hard error.

> **Open item:** verify at runtime whether Hermes exposes the Slack user ID to
> tool subprocess env. If yes, use env. If no, add it to the system prompt and
> have skills accept `--user`. Either way the shared helper
> `skills/_lib/creds.sh` is the only code path that reads from the vault.

## OAuth for per-user Google / AWS (no inbound port)

Services that authenticate real humans use **OAuth 2.0 Device Authorization
Grant** (RFC 8628). This is the same flow as `gh auth login`, `aws sso login`,
and "plug TV into Netflix":

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

No callback URL, no port forwarding, no ngrok. Works identically on your
laptop and on the EC2 instance.

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
