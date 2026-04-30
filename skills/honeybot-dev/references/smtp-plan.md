# Honeybot outbound mail — design notes

Where we've landed on letting honeybot send email. Primary use case is
the **cross-provider identity-linking flow** (verify the user controls
the email a new auth provider asserted before attaching it to their
unified profile). Open WebUI's password-reset path is a downstream
consumer of the same relay, not the reason this exists.

The point of this doc: when a future session asks "can honeybot send
email" or "what's our SMTP story," don't redesign from scratch — pick
this up. **Implementation contract** lives in `docs/email-verification.md`.

## Decision

Use **AWS SES SMTP** (`email-smtp.us-east-1.amazonaws.com:587`, STARTTLS).
Custom MAIL FROM domain `mail.honeymanenterprises.com` so bounces stay
out of the apex. From: `noreply@honeymanenterprises.com` (fire-and-forget
— replies hit the SES suppression list, no human inbox).

Why SES over the alternatives:

| Option                        | Verdict | Reason |
|-------------------------------|---------|--------|
| **AWS SES SMTP (chosen)**     | ✅      | DKIM/SPF/MX records auto-publish into Route 53 (we already host the zone there); bounce subdomain isolates apex DMARC; same vendor as EC2/Route53 — one fewer auth surface to rotate; no human seat required for a "service mailbox"; least-privilege IAM (only `ses:SendRawEmail`) |
| Workspace SMTP relay          | ⚠️      | Initially chosen for "we already have Workspace." Rejected on second pass: requires a real Workspace user with 2-Step + an app password (more credential lifecycle), bounces share the apex domain, and Workspace doesn't auto-publish DKIM/SPF the way Route 53 ↔ SES does |
| Plain `smtp.gmail.com`        | ❌      | Couples to a real human mailbox; MAIL FROM must be that mailbox or a verified alias; 500/day cap |
| Gmail API (OAuth send)        | ❌      | Per-user OAuth refresh dance — wrong fit for a service container |
| Postmark / Resend / SendGrid  | ⚠️      | Viable, but extra vendor + extra bill + extra DKIM dance. Revisit only if SES quotas / deliverability become real |

## Sender shape

```
MAIL FROM (envelope): bounce-handler@mail.honeymanenterprises.com   (SES-managed)
From (header):        Honeybot <noreply@honeymanenterprises.com>
Reply-To:             (none — fire-and-forget)
```

`noreply@honeymanenterprises.com` does NOT need to be a real mailbox —
SES accepts any From: in the verified domain. Bounces go to the SES
account-level suppression list automatically (and optionally to an SNS
topic if we wire one later).

## 1Password layout (current)

```
op://Honeybot/SMTP/host           = email-smtp.us-east-1.amazonaws.com
op://Honeybot/SMTP/port           = 587
op://Honeybot/SMTP/username       = <SES SMTP user — looks like AKIA...>
op://Honeybot/SMTP/app_password   = <SES SMTP password — derived, mixed-case>
op://Honeybot/SMTP/mail_from      = noreply@honeymanenterprises.com
op://Honeybot/SMTP/mail_from_name = Honeybot
```

`username` / `app_password` are **SES SMTP credentials**, not the IAM
access key/secret. Generate them via SES Console → SMTP settings →
Create SMTP credentials. The IAM user behind them (`honeybot-ses-smtp`)
holds only `AmazonSesSendingAccess` (= `ses:SendRawEmail`).

## Repo wiring (already landed)

1. **`.env.schema`** — `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`,
   `SMTP_PASSWORD`, `SMTP_MAIL_FROM`, `SMTP_MAIL_FROM_NAME` resolved
   via varlock from `op://Honeybot/SMTP/*`. All optional at the
   schema layer — `send_email.send()` raises `SMTPNotConfigured`
   if any required field is empty, every consumer must handle that
   as "feature off."

2. **`scripts/seed-vault.sh`** — `ensure_item "SMTP"` creates an
   empty placeholder on first boot so op() resolution doesn't fail
   `itemNotFound`. Subsequent boots skip it — 1Password edits survive
   any number of redeploys.

3. **`skills/_lib/send_email.py`** + `send-email.sh` — single
   source-of-truth sender. Stdlib only (smtplib + email.mime).
   Every consumer (Python or shell) routes through this. Nobody
   invents new env names, nobody touches op:// or smtplib directly.

4. **`docs/email-verification.md`** — full L0–L3 layer diagram +
   issue/store/send/consume/attach contract every verification flow
   must follow + the SES setup walkthrough.

## SES bring-up steps (browser, NOT in PR)

Walkthrough lives in `docs/email-verification.md` §"SMTP relay setup
(AWS SES)". Summary:

1. SES → Verified identities → Create identity for the apex domain
   with custom MAIL FROM `mail.honeymanenterprises.com` and Easy
   DKIM. ✅ "Publish DNS records to Route 53" — SES drops the
   records into our zone automatically.
2. Add apex SPF (`v=spf1 include:amazonses.com ~all`) and DMARC
   (`v=DMARC1; p=none; …`) via Route 53 if not present.
3. Request production access (out of sandbox) — usually <24h.
4. SES → SMTP settings → Create SMTP credentials → IAM user
   `honeybot-ses-smtp`. Download the CSV (one-shot reveal).
5. Populate the `SMTP` item in 1Password from the CSV + the values
   in the table above.
6. `docker compose restart honeybot`. Smoke-test via
   `python3 .../send_email.py --to verified@addr --subject test --body test`.

## Reuse beyond Open WebUI

The `SMTP_*` envs are intentionally backend-agnostic. Future surfaces —
webhook-triggered alerts, weekly digest from a scheduled job, ad-hoc
skill emails — should call `skills/_lib/send_email.send()` rather than
re-defining their own SMTP envs or reaching for `smtplib` directly. If
we ever swap backends again (e.g. SES → Postmark, or to add a fallback
provider), only `send_email.py` changes — every consumer is unaffected.
