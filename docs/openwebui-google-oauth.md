# Open WebUI — "Login with Google"

Lets people sign in to Open WebUI (`https://honeybot.honeymanenterprises.com`)
with their Google Workspace account instead of a local password. It's Open
WebUI's built-in OIDC — no fork, just config + a Google OAuth client.

The repo side is already wired (docker-compose.yml + secrets plumbing).
What's left is a one-time Google Cloud setup and pasting two values into
1Password.

## Why this is nice for honeybot

A Google login proves the user controls that Workspace email — the same
fact the OTP identity gate (`otp-identity-verification`) establishes with
an emailed code, but stronger (Google asserts it directly). Today they're
independent; a future enhancement could let a Google-authenticated Open
WebUI session skip the OTP step. Not built yet — noted for later.

## What's wired in the repo

- **docker-compose.yml** (`openwebui.environment`): `ENABLE_OAUTH_SIGNUP`,
  `OAUTH_MERGE_ACCOUNTS_BY_EMAIL`, `OAUTH_ALLOWED_DOMAINS=honeymanenterprises.com`,
  `GOOGLE_REDIRECT_URI`. Client id/secret are NOT set here (they'd be
  shadowed by Compose ${} at parse time) — they arrive via `.env.runtime`.
- **scripts/seed-vault.sh**: creates `op://Honeybot/GoogleOAuth-OpenWebUI/`
  with empty `client_id` + `secret_id` on first boot.
- **scripts/emit-runtime-env.sh**: emits `GOOGLE_CLIENT_ID` /
  `GOOGLE_CLIENT_SECRET` into `.env.runtime`. Empty = Google button hidden;
  Open WebUI still boots.
- **nginx**: no change — the apex vhost already proxies `/oauth/*` to
  Open WebUI under `location /`.

## Step 1 — OAuth consent screen (once per project)

Google Cloud Console → **APIs & Services → OAuth consent screen**:

1. **User type: Internal** — this is the big one. Internal restricts sign-in
   to your Workspace org (`honeymanenterprises.com`) at the Google level, so
   no external Google account can even start the flow. (Requires the project
   to live in the Workspace org.)
2. App name: `Honeybot` (or "Honeyman Open WebUI"). Support email: yours.
3. Scopes: the defaults `openid`, `email`, `profile` are enough — no extra
   scopes, no verification review needed for Internal.
4. Save.

## Step 2 — Create the OAuth client (Web application)

Google Cloud Console → **APIs & Services → Credentials → Create credentials
→ OAuth client ID**:

1. **Application type: Web application** (NOT Desktop — that's the separate
   per-user Gmail/Calendar client at `op://Honeybot/GoogleOAuth/`).
2. Name: `Open WebUI`.
3. **Authorized JavaScript origins**:
   `https://honeybot.honeymanenterprises.com`
4. **Authorized redirect URIs** (must match `GOOGLE_REDIRECT_URI` exactly):
   `https://honeybot.honeymanenterprises.com/oauth/google/callback`
5. **Create** → copy the **Client ID** and **Client secret** (the secret is
   shown once; you can reset it later if lost).

## Step 3 — Store the credentials in 1Password

In the **Honeybot** vault, open **GoogleOAuth-OpenWebUI** (auto-created by
seed-vault) and set:

| Field | Value |
|---|---|
| `client_id` | the Web client ID (`...apps.googleusercontent.com`) |
| `secret_id` | the Web client secret |

## Step 4 — Reload

```bash
docker compose up -d            # re-runs secrets-init → rewrites .env.runtime
# or, if only the vault changed and secrets-init already ran this boot:
docker compose up -d --force-recreate secrets-init openwebui
```

`secrets-init` reads the two values from 1Password into `.env.runtime`, and
Open WebUI reads them via `env_file` on start. Then visit
`https://honeybot.honeymanenterprises.com/` — a **"Continue with Google"**
button appears on the sign-in page.

## Verify

- The Google button renders on the login page.
- Signing in with an `@honeymanenterprises.com` account creates/merges an
  Open WebUI account and lands you in the app.
- A non-Workspace Google account is rejected (Internal consent screen +
  `OAUTH_ALLOWED_DOMAINS`).

## Notes / options

- **Merge behavior**: `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true` links a Google
  login to an existing same-email password account (e.g. your bootstrap
  admin). Only safe because sign-in is domain-restricted; keep it that way.
- **Google-only login**: once Google works, you can hide the password form
  entirely by adding `ENABLE_LOGIN_FORM: "false"` to the openwebui
  `environment:` block. Do this only *after* confirming a Google admin
  login works, or you can lock yourself out.
- **Redirect URI mismatch** is the #1 failure: the value in Google Cloud
  must byte-for-byte match `GOOGLE_REDIRECT_URI` (scheme, host, `/oauth/
  google/callback`, no trailing slash).

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `redirect_uri_mismatch` | URI in Google ≠ `GOOGLE_REDIRECT_URI` | Make them identical |
| No Google button | client id/secret empty in `.env.runtime` | Fill the vault item, re-run secrets-init |
| `403: org_internal` for you | Your account isn't in the Workspace org | Use your `@honeymanenterprises.com` account |
| Button works, login denied | domain not allowed | Confirm `OAUTH_ALLOWED_DOMAINS` + Internal consent screen |
