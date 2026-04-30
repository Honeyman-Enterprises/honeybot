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

## SMTP relay setup (one-time, manual)

The bot doesn't try to provision the relay automatically — same posture
as 1Password vault creation, which is a human decision.

1. In the Workspace Admin Console, enable the SMTP relay service:
   Apps → Google Workspace → Gmail → Routing → SMTP relay service →
   Add: Allowed senders = "Only registered Apps users in my domains",
   Authentication = "Require SMTP auth".
2. Pick (or create) a Workspace user that the bot will authenticate as.
   2-Step Verification must be ON for that user.
3. Sign in as that user → Account → Security → 2-Step Verification →
   App passwords → generate one for "Mail" / "Other (honeybot SMTP)".
   Copy the 16-char password.
4. In 1Password, edit the `SMTP` item in the `Honeybot` vault:
   - `host` = `smtp-relay.gmail.com`
   - `port` = `587`
   - `username` = the Workspace user from step 2
   - `app_password` = the 16-char value from step 3
   - `mail_from` = `noreply@<your-domain>` (does NOT need to be a real
     mailbox — relay accepts any From: in your verified domains)
   - `mail_from_name` = whatever display name you want, e.g. `Honeybot`
5. `docker compose restart honeybot` (or wait for the redeploy sidecar's
   next poll). Varlock re-reads SMTP_* on container start.

The seed script (`scripts/seed-vault.sh`) creates the placeholder item
on first boot but never overwrites filled values, so you can repeat the
1Password edits whenever you rotate the app password without code
changes.

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
