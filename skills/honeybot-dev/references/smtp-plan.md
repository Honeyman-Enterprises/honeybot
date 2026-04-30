# Honeybot outbound mail — design notes

Where we've landed on letting honeybot send email (password-reset links
from Open WebUI, account-verification flows, future notification surfaces).
Status as of 2026-04-30: **decided, not yet implemented.** No SMTP
scaffolding exists in the repo — `.env.schema`, `secrets-init`, and the
`openwebui` service block all need wiring.

The point of this doc: when a future session asks "can honeybot send email"
or "what's our SMTP story," don't redesign from scratch — pick this up.

## Decision

Use **Google Workspace SMTP relay** (`smtp-relay.gmail.com:587`, STARTTLS).

Why this over alternatives:

| Option                        | Verdict | Reason |
|-------------------------------|---------|--------|
| Workspace SMTP relay (chosen) | ✅      | Service-style sender, can MAIL FROM any `*@honeymanenterprises.com`, 10k/day per user, app-password auth |
| Plain `smtp.gmail.com`        | ❌      | Couples to a real human mailbox; MAIL FROM must be that mailbox or a verified alias; 500/day cap |
| Gmail API (OAuth send)        | ❌      | Requires per-user OAuth refresh dance — wrong fit for a service container |
| AWS SES                       | ⚠️      | Viable, but adds another vendor + DKIM/SPF setup we don't have configured for the domain |
| Postmark / Resend             | ⚠️      | Same — extra vendor. Revisit if Workspace relay rate-limits become real |

## Sender shape

```
MAIL FROM: noreply@honeymanenterprises.com
From:      Honeybot <noreply@honeymanenterprises.com>
```

`noreply@…` does NOT need to be a real Workspace user — Workspace SMTP
relay accepts any address in our domains as MAIL FROM. (Optional cleanup:
create it as a Group with posting locked down, so any reply goes to a
dead-letter group rather than bouncing.)

## 1Password layout

```
op://Honeybot/SMTP/host           = smtp-relay.gmail.com
op://Honeybot/SMTP/port           = 587
op://Honeybot/SMTP/username       = <relay-auth-user>@honeymanenterprises.com
op://Honeybot/SMTP/app_password   = <16-char Workspace app password>
op://Honeybot/SMTP/mail_from      = noreply@honeymanenterprises.com
op://Honeybot/SMTP/mail_from_name = Honeybot
```

`username` is whichever Workspace user generated the app password. Picking
a dedicated `bot@…` user (rather than a human's account) ages better.

## Repo wiring (one PR)

1. **`.env.schema`** — add varlock entries pulling each field from the
   1Password item above into `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`,
   `SMTP_PASSWORD`, `SMTP_MAIL_FROM`, `SMTP_MAIL_FROM_NAME`.

2. **`scripts/seed-vault.sh` / secrets-init** — emit the resolved values
   into `.env.runtime` so non-Varlock-aware containers (openwebui, ES,
   neo4j) can `env_file` them.

3. **`docker-compose.yml` `openwebui` service** — wire Open WebUI's native
   SMTP envs (their names, not ours):
   ```yaml
   SMTP_HOST: ${SMTP_HOST}
   SMTP_PORT: ${SMTP_PORT}
   SMTP_USERNAME: ${SMTP_USERNAME}
   SMTP_PASSWORD: ${SMTP_PASSWORD}
   SMTP_FROM_EMAIL: ${SMTP_MAIL_FROM}
   SMTP_FROM_NAME: ${SMTP_MAIL_FROM_NAME}
   SMTP_USE_TLS: "true"
   ```
   Then flip `ENABLE_EMAIL_VERIFICATION: "true"` and (once Eric's admin
   account exists) `ENABLE_SIGNUP: "false"`.

4. **`scripts/smtp-smoke.sh`** (optional but cheap) — connects to the
   relay, runs EHLO + STARTTLS + AUTH, sends a 1-line test email to a
   provided address, exits 0/1. Use for post-deploy validation and
   future regression-checking.

## Workspace admin steps (browser, NOT in PR)

1. Admin Console → Apps → Google Workspace → Gmail → Routing → **SMTP
   relay service** → Add:
   - Allowed senders: *Only addresses in my domains*
   - Authentication: *Require SMTP authentication*
   - Encryption: *Require TLS*
2. Pick or create the auth user (e.g. `bot@honeymanenterprises.com`).
3. That user → Account → 2-Step Verification ON → **App passwords** →
   generate one labeled `honeybot-smtp-relay`.
4. Paste the 16-char password into 1Password as
   `op://Honeybot/SMTP/app_password`.

## Reuse beyond Open WebUI

The `SMTP_*` envs are intentionally generic. Future surfaces — webhook-
triggered alerts, weekly digest from a scheduled job, ad-hoc skill emails —
should read the same envs rather than re-defining their own. If a future
skill needs to send mail from a Python script in the honeybot container,
use stdlib `smtplib` against `SMTP_HOST:SMTP_PORT` with STARTTLS and the
existing creds — don't reach for an SDK.
