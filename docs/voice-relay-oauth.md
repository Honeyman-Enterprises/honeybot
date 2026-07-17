# Voice-relay OAuth — self-hosted MCP authorization server (Google upstream)

**Goal:** a *proper* MCP connector you add on your phone (Claude/ChatGPT
mobile), authenticated by signing in with Google — no config file, no
pasted bearer.

**Status: design (API-verified), not yet built.** Every SDK fact below was
checked against `mcp==1.9.4`. This is security-critical auth infrastructure
and the mobile client handshake can't be tested from the repo, so it gets
built as its own reviewed increment (see "Gates").

## Why this shape

- **Mobile forces OAuth.** On a phone you can't drop a config file; the
  app's "add connector" flow runs an OAuth authorization-code + PKCE dance.
  So the relay must become an OAuth-protected MCP server.
- **Google can't be the AS directly.** MCP clients self-register via
  Dynamic Client Registration (RFC 7591); Google doesn't support DCR. So
  the relay runs a thin **authorization server** that speaks the MCP auth
  spec *and* delegates the actual login to Google. Google = identity; our
  AS = the glue that issues tokens the MCP client and the relay understand.

## Verified SDK facts (mcp 1.9.4)

- **Implement** `mcp.server.auth.provider.OAuthAuthorizationServerProvider`:
  `get_client`, `register_client`, `authorize(client, params) -> str`
  (returns a redirect URL — we return Google's), `load_authorization_code`,
  `exchange_authorization_code -> OAuthToken`, `load_access_token(token) ->
  AccessToken|None`, refresh + `revoke_token`.
- **The SDK verifies PKCE** (`code_verifier` vs `AuthorizationCode.
  code_challenge`, S256) in its `/token` handler — we do NOT hand-roll it.
- **Wiring:** `FastMCP("honeybot", auth_server_provider=provider,
  auth=AuthSettings(issuer_url=…, client_registration_options=…))`.
- **Routing (critical):** `mcp.streamable_http_app()` exposes, at its ROOT:
  `/.well-known/oauth-authorization-server`, `/authorize`, `/token`,
  `/register`, and `/mcp`. So this app must be served at the **root of the
  voice subdomain** — the OAuth discovery endpoint has to be at
  `https://voice.honeybot.honeymanenterprises.com/.well-known/…`, not under
  `/mcp`. (This changes the relay's app structure — see "Restructure".)
- **Custom routes:** `@mcp.custom_route("/oauth/callback", methods=["GET"])`
  for the Google redirect target.
- **Identity in the tool:** `mcp.server.auth.middleware.auth_context.
  get_access_token()` returns the validated `AccessToken`. We subclass it to
  carry `slack_uid` + `email`, so `ask_honeybot` reads identity from the
  *validated token*, not a header — replacing the current bearer hack.

## The federation flow

```
Claude/ChatGPT (phone)                 voice-relay AS              Google
  │  GET /.well-known/oauth-authorization-server → discovers endpoints
  │  POST /register (DCR) → client_id                         (SDK handles)
  │  GET /authorize?client_id&redirect_uri&code_challenge&state
  │        └─► provider.authorize(): store pending{their redirect_uri,
  │            code_challenge, state, client_id} keyed by OUR state;
  │            return Google auth URL (our /oauth/callback as redirect,
  │            scope openid+email, our state) ───────────────────► login
  │                                                    Google ◄── user signs in
  │  Google → GET /oauth/callback?code&state (our custom route)
  │        └─► exchange Google code → id_token → email;
  │            verify domain; slack_uid_for_email(email) → UID;
  │            mint OUR AuthorizationCode(client_id, their redirect_uri,
  │            code_challenge, +slack_uid,+email); redirect to THEIR
  │            redirect_uri?code=ours&state=theirs ──────────────►
  │  POST /token (code + PKCE verifier)  (SDK verifies PKCE)
  │        └─► provider.exchange_authorization_code(): issue opaque
  │            access token bound to {slack_uid,email,client_id,exp}
  │  → uses token as Bearer on /mcp; provider.load_access_token() validates
  │    → AccessToken(slack_uid=…); ask_honeybot() reads it. No OTP, no paste.
```

## Token & storage model

- **Access/refresh tokens:** opaque (`secrets.token_urlsafe`), NOT JWT —
  avoids hand-rolled crypto / a JWT lib. Stored server-side with
  `{slack_uid, email, client_id, scopes, expires_at}`. `load_access_token`
  is a lookup + expiry check.
- **Persistence:** the token + registered-client stores live on the
  relay's `/data` volume (same volume the voice-token map uses), so a
  connector survives a relay restart (no forced re-login). Authorization
  codes and pending-authorize state are short-lived and in-memory.
- **Slack UID mapping:** reuse `otp_auth.slack_uid_for_email` (already
  built + tested) — the Google-verified email resolves to the Slack UID the
  same way the auth bridge does.

## Restructure required

Today the relay is a FastAPI app that *mounts* the MCP app at `/mcp`. Since
OAuth endpoints must be at root, the MCP `streamable_http_app()` becomes the
**root ASGI app** for the voice subdomain, and the relay's own routes move
onto it via `@mcp.custom_route`:

- `/mcp` — MCP stream (SDK)
- `/authorize` `/token` `/register` `/.well-known/oauth-authorization-server`
  — OAuth (SDK)
- `/oauth/callback` — Google redirect (custom_route)
- `/v1/voice/ask` — Siri/HTTP ingress (custom_route)
- `/healthz` — (custom_route)

`/admin/*` and `/status` stay internal (nginx already blocks them).

## Config additions

| Var | Source | Purpose |
|---|---|---|
| `VOICE_PUBLIC_URL` | compose | issuer, e.g. `https://voice.honeybot.honeymanenterprises.com` |
| `VOICE_OAUTH_GOOGLE_CLIENT_ID` / `_SECRET` | `.env.runtime` (1Password) | a Google **Web** client whose redirect URI is `…/oauth/callback` |
| `OAUTH_ALLOWED_DOMAINS` | compose (reuse) | `honeymanenterprises.com` |
| `SLACK_BOT_TOKEN` | `.env.runtime` (reuse) | email→UID via `users.lookupByEmail` |

The Google client here is a **third** distinct OAuth client (separate from
`GoogleOAuth` = Gmail CLI Desktop, and `GoogleOAuth-OpenWebUI` = Open WebUI
web login). Its authorized redirect URI is
`https://voice.honeybot.honeymanenterprises.com/oauth/callback`.

## Security considerations (this is an auth server)

- **PKCE** mandatory (SDK-enforced). **State** parameter binds our
  Google round-trip to the client's request — validate it on callback.
- **redirect_uri validation**: only redirect to a client's *registered*
  redirect_uri (SDK checks against the DCR record); never an open redirect.
- **Domain restriction**: reject any Google identity outside
  `OAUTH_ALLOWED_DOMAINS` before minting a code — same posture as the bridge.
- **Token expiry + revocation**: short access-token TTL, refresh support,
  `/revoke`. Tokens are opaque and server-validated.
- **DCR limits**: cap registered clients / expire stale ones; a public
  `/register` is inherent to MCP but shouldn't be an unbounded write.
- **Relationship to existing paths**: this OAuth path is for MCP clients
  (Claude/ChatGPT). **Siri keeps using the static voice token** (HTTP
  `/v1/voice/ask`). The two coexist; the OAuth token and the voice token
  both resolve to the same Slack UID.

## Build plan & gates

1. Provider core (`oauth/provider.py`, `oauth/google.py`, `oauth/store.py`,
   AccessToken/AuthorizationCode subclasses) + **unit tests** (authorize→
   state store, google-callback→code with mocked Google, code exchange,
   token issue/validate, domain reject, unknown-email reject).
2. Relay restructure (MCP app as root + custom_route for callback/Siri/
   healthz); `ask_honeybot` reads `get_access_token().slack_uid`.
3. Config + 1Password item + emit + compose + nginx (issuer at root).
4. **Gates before it's trusted:**
   - unit tests green,
   - a **security review** (this is auth — run `security-review` / a
     security agent over it),
   - **live handshake** against a real Claude (and/or ChatGPT) mobile
     connector, watching the relay log through discover→register→authorize
     →Google→callback→token→/mcp.

Until the live handshake + security review pass, this stays behind its
config (no Google client id → the AS is dormant, MCP falls back to the
static bearer path).
