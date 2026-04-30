# Email Ownership Verification (cross-provider identity linking)

**Audience:** future-Eric, future-contributors. Read this before adding any
auth surface that lets a user attach a new identity provider to an existing
honeybot profile.

## Why this exists

honeybot's identity story is "one human → one unified profile, with N
auth providers attached to it." A profile may be linked to:

- a Slack user ID (via the bot's allow-list)
- a Google account (via OAuth, used for Gmail/Calendar skills)
- a GitHub account (via OAuth, used for `honeybot-dev`)
- a Microsoft / Apple / future-IDP account (linked through Open WebUI's
  account system or a future direct-OIDC flow)

Each of those providers asserts an email address. We **must not** trust
those assertions transitively. When a user is logged in via Provider A
and asks to attach Provider B, B's claim that the user owns
`user@example.com` is just B's word — we have no relationship with B's
operator. The only way to know that the human in front of A also
controls `user@example.com` is to send a one-time secret to that
address and require them to prove receipt.

That's email ownership verification. It's a primitive, not a feature.
This doc describes the contract every consumer should follow.

## Anti-goals

- **Not** a replacement for OAuth. OAuth proves "you control this
  Google account right now"; email verification proves "you control
  the inbox at this address." They're complementary, not equivalent.
- **Not** a password reset flow. Open WebUI happens to use SMTP for its
  own internal account recovery — that's a downstream consumer of the
  same SMTP relay, but it lives entirely inside Open WebUI's runtime
  and uses its own token store. honeybot doesn't issue or consume Open
  WebUI's reset tokens.
- **Not** a delivery-guarantee channel. Transactional email through
  smtp-relay.gmail.com is best-effort. Verification flows MUST tolerate
  the email never arriving (resend button, fallback channel, expiry).

## Layers

```
┌─────────────────────────────────────────────────────────────┐
│ L3: consumer (e.g. "link a Microsoft account to my profile")│
│     — generates a token, calls L2 to send, persists token   │
│     — handles user-clicks-link, validates, attaches identity│
└────────────────────┬────────────────────────────────────────┘
                     │ uses
┌────────────────────▼────────────────────────────────────────┐
│ L2: skills/_lib/send_email.py + send-email.sh               │
│     — single place that knows how to talk SMTP              │
│     — reads SMTP_* env, fails closed if not configured      │
│     — STARTTLS, AUTH PLAIN, send_message                    │
└────────────────────┬────────────────────────────────────────┘
                     │ uses
┌────────────────────▼────────────────────────────────────────┐
│ L1: SMTP_* env vars (varlock-resolved at container start)   │
└────────────────────┬────────────────────────────────────────┘
                     │ resolves
┌────────────────────▼────────────────────────────────────────┐
│ L0: op://Honeybot/SMTP/{host,port,username,app_password,    │
│                          mail_from,mail_from_name}          │
│     — placeholder seeded by scripts/seed-vault.sh           │
│     — populated by a human via the 1Password UI             │
└─────────────────────────────────────────────────────────────┘
```

L0–L2 are built and shipped today. L3 is per-consumer and unbuilt; this
doc tells future L3 implementers what the contract is.

## L2 contract — sending mail

Every place that sends email goes through `skills/_lib/send_email.py`,
either by direct Python import or via the `send-email.sh` shell wrapper.
Nobody calls `smtplib` directly, nobody invents their own env names,
nobody reads `op://Honeybot/SMTP/*` outside the varlock pre-resolution
path.

```python
from skills._lib.send_email import send, SMTPNotConfigured, SMTPSendError

try:
    send(
        to="user@example.com",
        subject="Verify your address for honeybot",
        body=text_fallback,
        html=html_body,             # optional
        reply_to="support@…",       # optional
    )
except SMTPNotConfigured:
    # Surface to the user as a feature-disabled message; do NOT retry.
    return _user_error("Email verification is not enabled on this deployment.")
except SMTPSendError as e:
    # Transient — log and offer resend. Don't expose the SMTP error verbatim.
    log.warning("send failed: %s", e)
    return _user_error("Couldn't send the verification email. Try again?")
```

```bash
# Same thing from a shell skill
if ! ../_lib/send-email.sh --to "$EMAIL" \
       --subject "Verify your address" \
       --body "Open the link: $LINK"; then
  rc=$?
  case $rc in
    4) echo "SMTP not configured on this deployment" >&2; exit 64 ;;
    5) echo "send failed; please retry" >&2; exit 65 ;;
    *) echo "unexpected send-email error rc=$rc" >&2; exit 70 ;;
  esac
fi
```

## L3 contract — the verification flow

Pseudocode for any consumer that's adding email-ownership verification.
The TL;DR is: **issue → store → send → consume → attach**. Don't shortcut.

### 1. Issue

```python
token = secrets.token_urlsafe(32)          # 256 bits, URL-safe
issued_at = time.time()
ttl = 15 * 60                              # 15 minutes; tune per-flow
challenge = {
  "token": token,
  "profile_id": profile_id,                # the EXISTING profile being linked-to
  "claimed_email": email,                  # what the new provider asserted
  "claimed_provider": "microsoft",         # which IDP is being attached
  "issued_at": issued_at,
  "expires_at": issued_at + ttl,
  "consumed_at": None,
}
```

### 2. Store

Store the challenge somewhere with a TTL. Choices, ranked:

- **Honcho** (preferred): we already use it for per-profile state.
  Namespace verification tokens under `profile/{profile_id}/email_verify/{token}`.
- **Elasticsearch**: works, but ES is meant for search, not key-value;
  use only if Honcho isn't available for some reason.
- **Local sqlite under ~/.hermes/data/**: don't. State doesn't survive
  container recreate cleanly, and the redeploy sidecar recreates often.

Whichever store you pick, **index by token**, not by email. An attacker
who controls one inbox shouldn't be able to enumerate other pending
verifications on the same address.

### 3. Send

Build a verification URL the user can click from their inbox:

```
https://<honeybot-public-host>/auth/verify-email?t=<token>
```

The URL goes through nginx → the api_server → a verification handler
that calls into L3 #4 (consume). Plain-text body is mandatory; HTML is
encouraged for clickability.

```python
from skills._lib.send_email import send

verify_url = f"https://{HOST}/auth/verify-email?t={token}"
send(
    to=email,
    subject="Confirm your email for honeybot",
    body=(
        f"You're attaching {email} to your honeybot profile.\n\n"
        f"Open this link within 15 minutes to confirm:\n  {verify_url}\n\n"
        "If you didn't ask to link this address, you can ignore this email."
    ),
    html=(
        f"<p>You're attaching <b>{email}</b> to your honeybot profile.</p>"
        f"<p><a href=\"{verify_url}\">Confirm within 15 minutes</a></p>"
        "<p>If you didn't ask to link this address, you can ignore this email.</p>"
    ),
)
```

### 4. Consume

The verification handler receives the click, looks the token up, and
validates **all** of:

- token exists in the store
- `expires_at > now()`
- `consumed_at is None` (one-shot; reject reuse)
- the currently-authenticated session matches `profile_id`

If any check fails: 400/410. If all pass:

- mark `consumed_at = now()` (atomic — use a CAS / optimistic-lock so a
  concurrent click can't double-consume)
- attach `claimed_email` + `claimed_provider` to the profile
- return success

### 5. Attach

How "attach" is implemented depends on the linked-identity store, which
isn't built yet. When it lands, document it here and link from this
section. Until then: don't ship a verification flow that has nowhere to
write the result.

## Security notes

- **Tokens are bearer secrets.** Anyone holding the token can complete
  the verification. Never log them, never put them in URLs that get
  redirected through third parties, never include them in non-TLS
  responses.
- **Bind to the originating session.** The user who clicks the link
  must be the same session that initiated the link request. Otherwise
  an attacker who can read the victim's email can attach the victim's
  address to the attacker's profile — the inverse of what we want.
- **Rate-limit per (profile_id, email).** No more than N issues per
  hour. SMTP relays will quench you anyway; better to fail at our
  layer with a clear message.
- **Don't echo the token in error responses.** A wrong-token attempt
  should look identical to an expired-token attempt to anyone outside.
- **Header injection.** `send_email.py` builds the message via stdlib's
  `email.mime.*`, which handles header escaping correctly for any
  single-field input. If you start composing raw RFC822 by hand, stop
  and use the helper.

## SMTP relay setup (AWS SES, one-time, manual)

The bot doesn't try to provision the relay automatically — same posture
as 1Password vault creation, which is a human decision. Backend is
**AWS SES SMTP**, region `us-east-1` (matches `AWS_DEFAULT_REGION`
in `scripts/seed-vault.sh`). All clicks below assume `us-east-1`.

### Step 1 — Verify the domain identity

`AWS Console` → SES → confirm region `us-east-1` top-right.

1. **Configuration → Verified identities → Create identity**
2. Identity type: **Domain**, value: `honeymanenterprises.com`
3. ✅ **Use a custom MAIL FROM domain**:
   - MAIL FROM domain: `mail.honeymanenterprises.com`
   - Behavior on MX failure: `Use default MAIL FROM domain`
   - Why: bounces come from a subdomain so the apex stays DMARC-aligned
     and silent on the bounce path.
4. **DKIM**: ✅ Easy DKIM, RSA 2048-BIT.
5. ✅ **Publish DNS records to Route 53** (Route 53 hosts our zone, so
   SES publishes the records itself — three DKIM CNAMEs, one MAIL FROM
   MX, one MAIL FROM SPF TXT — auto-rolled into the hosted zone).
6. **Create identity**.

Watch the identity detail page: **DKIM configuration** flips from
`Pending` → `Successful` (usually <5 min). MAIL FROM also goes
`Successful` once the MX/SPF records propagate.

### Step 2 — Verify (or add) the apex SPF + DMARC records

SES auto-handles SPF for the *bounce* subdomain. The *apex* domain
still needs SPF (so SES is authorized to send) and a DMARC policy.

```bash
dig +short TXT honeymanenterprises.com   | tr -d '"' | grep -i spf1
dig +short TXT _dmarc.honeymanenterprises.com | tr -d '"'
```

You want:

| Record | Value |
|---|---|
| `TXT honeymanenterprises.com` | `v=spf1 include:amazonses.com ~all` (merge `include:`s if other senders exist; never publish two SPF records) |
| `TXT _dmarc.honeymanenterprises.com` | `v=DMARC1; p=none; rua=mailto:postmaster@honeymanenterprises.com; aspf=r; adkim=r` |

Add via Route 53 console or CLI. DMARC `p=none` is monitor-only; tighten
to `quarantine` or `reject` later after watching aggregate reports.

### Step 3 — Move out of sandbox

By default SES can only send TO verified addresses. Production access
lifts that.

SES Console → top of page → **Request production access**:
- Mail type: **Transactional**
- Website URL: `https://honeybot.honeymanenterprises.com`
- Use case: paste the canonical description from the linking flow:

  > Honeybot is an internal Slack-fronted assistant for Honeyman
  > Enterprises. We use SES exclusively for transactional verification
  > mail: when a user attaches a new auth provider (Google, GitHub,
  > Microsoft) to their unified Honeybot profile, we send a one-time
  > link to the email address that provider asserted, so the user can
  > prove they control that inbox. Recipients have all initiated the
  > linking action themselves; we never send marketing or unsolicited
  > mail. Estimated volume: <500 messages/month, transactional only.

Approval is usually <24h. You can finish the rest of the wiring while
the request bakes — sandbox mode is enough to smoke-test against any
verified email.

### Step 4 — Generate SES SMTP credentials

SES Console → left nav → **SMTP settings**.

1. Note the SMTP endpoint: `email-smtp.us-east-1.amazonaws.com`, port 587.
2. **Create SMTP credentials**:
   - IAM user name: `honeybot-ses-smtp`
   - Click **Create user**.
3. **Download credentials** (CSV) — the SMTP user/password is shown
   exactly once. Same one-shot convention as Google's app passwords.

Behind the scenes AWS just:
- Created an IAM user `honeybot-ses-smtp`
- Attached `AmazonSesSendingAccess` (only `ses:SendRawEmail`)
- Generated an IAM access key
- Derived an SMTP password from the secret via the documented SigV4
  algorithm

The SMTP credentials are NOT the IAM access key/secret — only the
SMTP user and password go to honeybot.

### Step 5 — Populate the `SMTP` item in 1Password

In the **Honeybot** vault, open the **SMTP** item (auto-created as a
placeholder by `scripts/seed-vault.sh`). Set:

| Field | Value |
|---|---|
| `host` | `email-smtp.us-east-1.amazonaws.com` |
| `port` | `587` |
| `username` | SMTP user from step 4 (looks like `AKIA…`) |
| `app_password` | SMTP password from step 4 (mixed-case, sensitive) |
| `mail_from` | `noreply@honeymanenterprises.com` |
| `mail_from_name` | `Honeybot` |

Save. The `op` CLI picks up new fields immediately on next read; no
vault-side propagation delay.

### Step 6 — Reload + smoke

```bash
docker compose restart honeybot
docker compose logs -f honeybot 2>&1 | head -30
```

Smoke (sandbox-safe to any verified address until production access
lands):

```bash
docker exec honeybot bash -lc \
  'python3 /home/honeybot/.hermes/skills/_lib/send_email.py \
     --to YOUR_VERIFIED_EMAIL@example.com \
     --subject "honeybot SES smoke test" \
     --body "If you see this, SES → Honeybot is wired."'
```

Verify in the recipient's mail (Gmail's "Show original"):
- ✅ `SPF: PASS` (bounces via `mail.honeymanenterprises.com`)
- ✅ `DKIM: PASS` with `d=honeymanenterprises.com`
- ✅ `DMARC: PASS`

If DMARC fails on alignment, check the SES identity → MAIL FROM section:
the bounce subdomain status must be `Successful`.

### Common SES failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `554 Email address is not verified` | Sandbox mode; recipient unverified | Verify the recipient in SES, or wait for production access |
| `535 Authentication Credentials Invalid` | Used IAM access key as SMTP creds | Re-do step 4; SMTP creds ≠ IAM keys |
| `554 Local addresses…` | Domain identity not yet `Verified` | Watch SES identity page; DKIM must be `Successful` |
| Mail arrives, DMARC `FAIL: DKIM aligned=no` | Custom MAIL FROM misalignment | SES → identity → MAIL FROM → status must be `Successful` |
| Stuck `Pending verification` >30 min | Route 53 publish failed (e.g. CAA conflict) | SES → identity → Authentication tab shows the actual failure |

### Rotation

Rotate the SMTP password by going back to step 4 and clicking
**Reset SMTP credentials** on the existing IAM user. Update the
`app_password` field in 1Password. Restart honeybot. Old credentials
are revoked atomically by SES — no overlap window to manage.

The seed script (`scripts/seed-vault.sh`) creates the placeholder item
on first boot but never overwrites filled values, so 1Password edits
survive any number of redeploys.

## Local development

For local-dev hosts that don't run Open WebUI and don't need outbound
mail at all: leave the SMTP fields empty. `send_email.send()` raises
`SMTPNotConfigured`, which every consumer is required to handle as
"feature off" (not "bug"). Honeybot itself boots fine with empty SMTP.

If you want to **test** the flow locally without burning Workspace
quota, point SMTP_HOST/PORT at a local
[MailHog](https://github.com/mailhog/MailHog) container, set
SMTP_USERNAME/PASSWORD to anything, and you'll see captured messages in
MailHog's UI. The `op` CLI doesn't get involved — you can override via
`./op.env` for the local run.
