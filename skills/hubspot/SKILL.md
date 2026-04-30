---
name: hubspot
version: 0.1.0
description: Install the HubSpot CLI (@hubspot/cli) and authenticate an account using a Personal Access Key Michelle provides via Slack DM.
triggers:
  - "install hubspot"
  - "set up hubspot"
  - "authenticate hubspot"
  - "hubspot setup"
  - "connect hubspot"
capabilities:
  - hs_install
  - hs_auth
  - hs_accounts_list
---

# HubSpot Skill — v1 (install + auth)

> **🔐 OTP Identity Gate**: Non-Slack sessions (Open WebUI, Discord, API)
> must complete email-based identity verification before accessing credentials.
> If `creds.sh` returns exit code 4, follow the OTP flow in the
> `otp-identity-verification` skill before retrying.

## When to use
When Michelle asks you to set up, install, configure, or connect HubSpot. If
she asks for HubSpot *actions* (find a contact, update a deal) and the CLI
isn't installed or authed yet, run this skill first and then continue.

## Inputs
- **Slack user**: the person DMing you (must be in `SLACK_ALLOWED_USERS`).
- **HubSpot Personal Access Key**: obtained from Michelle via Slack DM at
  runtime. You must *never* ask her to paste it in a public channel.

## Steps

### 1. Confirm the CLI is available
The HubSpot CLI is pre-installed in the container. Run `hs --version` to
confirm and report the version to Michelle. If (rarely) it's missing, run
`./install.sh` \u2014 idempotent and safe to re-run.

### 2. Check whether an account is already authenticated
Run `hs accounts list`.
- If the output lists a portal, tell Michelle the portal name and stop \u2014 no
  re-auth needed.
- If empty or errors with "no accounts", proceed to step 3.

### 3. Request a Personal Access Key from Michelle (Slack DM only)
Send her this exact message:

> To connect HubSpot I need a Personal Access Key. Generate one here:
> https://app.hubspot.com/l/personal-access-key
>
> Paste the full key (starts with `pat-`) back to me in this DM. I will store
> it in 1Password and use it only for HubSpot API calls. I will never log it,
> echo it back, or share it.

### 4. Store the key in 1Password (never on disk)
When she replies with a string matching `pat-...`:

```bash
op item edit "HubSpot" --vault "Honeybot" personal_access_key="$PAK"
```

After writing, immediately scrub the value from working memory / chat context
before continuing. Do **not** echo the key back, even partially, in any Slack
message.

### 5. Re-resolve env and authenticate
The new value is picked up automatically on next `varlock run` invocation.
Run `./auth.sh`, which consumes `$HUBSPOT_PERSONAL_ACCESS_KEY` and runs
`hs auth` non-interactively.

### 6. Verify
Run `hs accounts list`. Report the portal name and ID to Michelle.

## Guardrails
- **Never** write the PAK to a file, log line, or Slack message.
- **Never** expose the PAK via `env` or `printenv` output sent to Slack.
- If Michelle pastes the key in a non-DM channel by accident, immediately
  message her asking to rotate it at https://app.hubspot.com/l/personal-access-key
  and do not store the leaked key.

## Follow-ups (future versions)
- v2: wrap `hs` CRM read commands (contacts, companies, deals) as tool calls.
- v3: wrap `hs` CRM write commands with a Slack confirmation block before
  execution.
- v4: workflow / pipeline actions, gated by an allowlist of pipeline IDs
  stored in 1Password.
