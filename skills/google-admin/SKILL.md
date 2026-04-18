---
name: google-admin
version: 0.1.0
description: Run GAM (Google Workspace admin) commands. BOT-LEVEL only, gated by an explicit admin allow-list.
triggers:
  - "gam"
  - "workspace admin"
  - "google workspace"
  - "create user"
  - "suspend user"
capabilities:
  - gam_run
---

# Google Workspace Admin Skill — v1 (GAM, bot-level)

## Identity model — IMPORTANT

This skill is an **exception** to the per-user identity model. GAM operates
via a Google Cloud **service account with domain-wide delegation**, which
means it can act as any user in the workspace (create users, read any
mailbox, modify any calendar). That power is stored at:

```
op://Honeybot/GoogleWorkspace Admin/service_account_json
```

It is **not** keyed on the requesting Slack user — there's only one service
account — so access is instead gated by an explicit allow-list:

```
op://Honeybot/GoogleWorkspace Admin/admin_slack_users   # comma-separated UIDs
```

Before running any `gam` command, this skill MUST confirm
`$HONEYBOT_SLACK_USER` is in that list. Anyone else gets refused with:

> This is a workspace-admin-only command. You're not on the admin list for
> Google Workspace. If this is a mistake, talk to whoever owns the
> Honeybot/GoogleWorkspace Admin vault item.

## When to use

Workspace admin ops: creating users, suspending accounts, transferring
drive ownership, pulling audit reports, managing groups/OUs. **Never** use
this skill for "read my email" — that's the per-user `google` skill (OAuth
device flow).

## First-run setup

1. Admin uploads service account JSON to 1Password once
   (`op://Honeybot/GoogleWorkspace Admin/service_account_json`).
2. On first skill invocation:
   ```bash
   mkdir -p ~/.gam
   op read "op://Honeybot/GoogleWorkspace Admin/service_account_json" \
     > ~/.gam/oauth2service.json
   chmod 600 ~/.gam/oauth2service.json
   gam oauth info   # sanity check
   ```
3. The service account JSON stays inside the container FS (not the image).
   On container restart, step 2 re-runs. On container rebuild, the workspace
   `~/.gam/` is gone and step 2 re-runs. Never baked into the image.

## Per-request invocation pattern

```bash
# Guard 1: user must be in admin allow-list
ADMINS="$(op read "op://Honeybot/GoogleWorkspace Admin/admin_slack_users")"
[[ ",${ADMINS}," == *",${HONEYBOT_SLACK_USER},"* ]] \
  || { echo "not authorized for GAM"; exit 1; }

# Guard 2: service account JSON present
[[ -f ~/.gam/oauth2service.json ]] || ../google-admin/bin/init.sh

# Run
gam "$@"
```

## Guardrails

- **Always** gate on the admin allow-list. No exceptions.
- **Never** expose the service account JSON contents in logs or Slack.
- Destructive ops (`delete user`, `suspend user`, `transfer`, `wipe`)
  require Slack confirmation.
- All `gam` invocations are logged with the Slack user ID of the requester
  so there's an audit trail back to a human.

## Out of scope

- Per-user Gmail/Calendar reads — use the `google` skill instead (OAuth
  device flow, scoped to the requester only).
- Anything that touches data outside the Google Workspace domain this
  service account is delegated to.
