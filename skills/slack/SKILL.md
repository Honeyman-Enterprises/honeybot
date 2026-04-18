---
name: slack
version: 0.1.0
description: Slack workspace operations using the bot's own token (v1). Per-user Slack identity is deferred to v2.
triggers:
  - "slack channel"
  - "slack user"
  - "post to slack"
  - "slack workspace"
capabilities:
  - slack_post
  - slack_read
  - slack_list
---

# Slack Skill — v1 (bot-level)

## Identity model

v1 uses the **bot's own** Slack tokens (`SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`)
that Hermes is already authenticated with. Good enough for:

- Posting messages to channels the bot has been invited to
- Reading history from public channels
- Listing users / channels
- Reacting to messages as the bot

v1 is **not** good enough for:

- Posting as a specific human ("send this as Michelle")
- Reading private DMs the bot isn't a member of
- Anything requiring a user scope the bot token doesn't carry

v2 (deferred) will store per-user `xoxp-` tokens at
`op://Honeybot/Slack-{SlackUserID}/user_token` and use them for user-scoped
operations. Follow the per-user pattern described in
`docs/identity-model.md`.

## When to use

Slack workspace operations that the bot can do on its own behalf. Common:

- "Summarize the last 20 messages in #general"
- "Post this update to #engineering"
- "Who's on PTO this week?" (reading a dedicated channel)

## Invocation

The Slack CLI (`slack`) is installed in the image but v1 mostly uses direct
Web API calls via `curl`, because they're lower-overhead and don't require
`slack login` state. Pattern:

```bash
curl -s -X POST https://slack.com/api/<method> \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d '{"channel": "C123...", "text": "hello"}'
```

`SLACK_BOT_TOKEN` is already in the subprocess environment (resolved by
varlock at container start).

## Guardrails

- **Never** log or echo `SLACK_BOT_TOKEN` / `SLACK_APP_TOKEN`.
- Posting to new channels: require Slack confirmation first, with the
  channel name and a preview of the message. Don't send silently.
- Bulk operations (post to 10+ channels, DM 10+ users): hard-refuse at v1.
- Anything involving the workspace admin API (user deactivation, channel
  archiving) is **out of scope** — use workspace admin tools, not the bot.
