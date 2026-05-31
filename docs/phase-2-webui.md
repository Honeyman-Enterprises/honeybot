# Phase 2: web frontend (Open WebUI)

Adds a chat web UI on top of the existing Hermes agent. Open WebUI (the
most-starred OpenAI-compatible frontend on GitHub, ~135k stars as of
April 2026) runs in its own container and speaks to honeybot through
Hermes' built-in `api_server` gateway adapter. TLS terminates at the
existing nginx (lua-resty-acme), reusing the same Let's Encrypt issuance
path that already serves `hooks.honeybot.honeymanenterprises.com`.

## Architecture after merge

```
                                    Internet
                                       │
                              honeybot.honeymanenterprises.com
                                  ↓ :443 (router → host :4433)
                                  ↓ :80  (router → host :8080, ACME only)
┌──────────────────────────────────────────────────────────────────────────┐
│                              host (Mac / EC2)                             │
│                                                                           │
│   ┌────────────────────────┐                                              │
│   │  nginx :8080,4433      │  OpenResty + lua-resty-acme.                 │
│   │  (TLS term + reverse   │  Whitelist:                                  │
│   │   proxy)               │    honeybot.honeymanenterprises.com          │
│   │                        │    hooks.honeybot.honeymanenterprises.com   │
│   └─┬──────────────┬───────┘                                              │
│     │ /            │ /webhooks/*                                          │
│     │              │                                                       │
│     │ honeynet     │ honeynet                                              │
│     ▼              ▼                                                       │
│   ┌──────────────────┐    ┌──────────────────────────────┐                 │
│   │   openwebui      │    │  honeybot                    │                 │
│   │   :8080          │    │  • slack gateway (Socket)    │                 │
│   │                  │    │  • api_server :8642 (NEW)    │                 │
│   │  user accounts,  │    │  • webhook :8644             │                 │
│   │  chat history,   │    │                              │                 │
│   │  RAG docs, files │    │                              │                 │
│   └────────┬─────────┘    └──────────┬───────────────────┘                 │
│            │                          ▲                                    │
│            │   honeynet               │                                    │
│            │   OpenAI-compat HTTP     │                                    │
│            └──────────────────────────┘                                    │
│                                                                           │
└──────────────────────────────────────────────────────────────────────────┘
```

The api_server adapter ships with hermes-agent — no new code in honeybot.
We just enable it via env vars and put nginx in front of the Open WebUI
that consumes it.

## What's in this PR

### New service (docker-compose.yml)

- `openwebui` — Open WebUI container (ghcr.io/open-webui/open-webui:main).
  - On `honeynet`. No `ports:` mapping — only nginx is the public surface.
  - Reads secrets from `.env.runtime` (resolved from 1Password by
    `emit-runtime-env.sh` at container start):
    - `OPENAI_API_KEY` — Hermes bearer token (from `op://Honeybot/HermesAPI/key`)
      so Open WebUI authenticates to honeybot:8642.
    - `WEBUI_SECRET_KEY` — signs Open WebUI's session JWTs (from
      `op://Honeybot/OpenWebUI/secret_key`).
  - `OPENAI_API_BASE_URL=http://honeybot:8642/v1` — uses Hermes as its
    sole model provider.
  - `ENABLE_OLLAMA_API=false` — we don't run Ollama.
  - `ENABLE_SIGNUP=true` — first signup becomes the local admin. Flip to
    `false` after admin account is created.
  - `WEBUI_URL=https://honeybot.honeymanenterprises.com` — server-side
    link generation (password reset, websocket origin checks).
  - Volume `openwebui-data` mounted at `/app/backend/data` for accounts,
    chats, RAG knowledge bases. Wiping it does NOT touch any Hermes
    state (sessions, memory, skills) — those live on `honeybot-data`.

### Vault items (scripts/seed-vault.sh)

- `op://Honeybot/HermesAPI/key` — auto-generated 32-byte token.
- `op://Honeybot/OpenWebUI/secret_key` — auto-generated 48-byte secret.

Both are auto-created on first vault seed, no human intervention. Empty
vault → fresh secrets → working stack.

### Schema additions (.env.schema)

- `API_SERVER_ENABLED=true`
- `API_SERVER_HOST=0.0.0.0`
- `API_SERVER_PORT=8642`
- `API_SERVER_KEY=op("op://Honeybot/HermesAPI/key")` (@required @sensitive)
- `API_SERVER_CORS_ORIGINS=https://honeybot.honeymanenterprises.com`
- `OPENWEBUI_SECRET_KEY=op("op://Honeybot/OpenWebUI/secret_key")` (@required @sensitive)

The honeybot container picks these up via varlock and starts the
`api_server` adapter alongside the Slack one. No code changes — Hermes'
gateway loader already handles env-driven enablement (see
`hermes-agent/gateway/config.py` `api_server_enabled`).

### Nginx changes (nginx/conf.d/honeybot.conf)

- Apex vhost (`honeybot.honeymanenterprises.com`) was a placeholder
  returning `"honeybot\n"`. Now reverse-proxies `/` to `openwebui:8080`
  with:
  - WebSocket upgrade headers (Open WebUI uses socket.io for streaming).
  - 600s `proxy_read_timeout` so long LLM streams don't 504.
  - `proxy_buffering off` so SSE tokens reach the browser as they arrive.
  - `client_max_body_size 100m` for RAG document uploads.
  - X-Forwarded-* headers so Open WebUI generates correct https:// links.
- `/healthz` preserved (returns locally, doesn't touch upstream — useful
  as an "is nginx alive" probe independent of Open WebUI).
- The `hooks.honeybot.*` vhost is untouched. Webhooks keep working.

### Port mapping change (docker-compose.yml)

Nginx was on host `80:80` and `443:443`. Now `8080:80` and `4433:443`.
The host (Mac) does router-level WAN port-forwarding from public :443 →
Mac :4433 and public :80 → Mac :8080. Public URLs stay the same (no
:4433 in the URL).

This frees the Mac itself to run other things on 80/443 if it ever
needs to. To deploy this stack on a host where nginx SHOULD bind 80/443
directly (e.g. a fresh EC2 box dedicated to honeybot), override the
`ports:` block in a compose overlay rather than editing in place.

## Why this isn't behind a profile / opt-in

Earlier drafts of this PR gated `openwebui` behind a Docker profile so
existing deployments wouldn't get a webui they didn't ask for. We
abandoned that:

1. Honeybot is intentionally multi-tenant via Hermes' identity model
   (per-user secrets in `op://Honeybot/{Service}-{SlackUserID}/...`).
   A web frontend that lets allowlisted users sign in is a natural
   extension of the bot, not an unrelated service.
2. Open WebUI's own auth gates the URL — opening port 443 doesn't open
   the bot to the world; it opens it to whoever has an Open WebUI
   account, which is empty until the admin signs up.
3. The api_server adapter that powers it is also useful to other
   clients (Claude Desktop via MCP, custom integrations, the webui
   itself). Enabling it once at the bot's level means everyone
   benefits.

If you redeploy honeybot somewhere you specifically don't want a
public webui (e.g. a dev EC2 with no DNS), set `API_SERVER_ENABLED=false`
in your `.env.local` and remove the `openwebui` service from a compose
overlay.

## What's NOT in this PR

- DNS-01 ACME flow. Port 80 is still required for HTTP-01 challenges.
  Closing port 80 entirely means switching lua-resty-acme to DNS-01
  via Route53 — separate PR. Until then, `:80` is reachable but only
  serves ACME challenges and a 301 to https://.
- Hermes API server CORS origins beyond apex. If we ever want to embed
  the bot in another domain (e.g. a Honeyman Enterprises SaaS), add
  the origin to `API_SERVER_CORS_ORIGINS` and to the autossl whitelist
  in `nginx/nginx.conf`.
- Per-user OAuth on Open WebUI (signing in with Google etc.). Open
  WebUI supports it; configure in its admin panel after first boot,
  no compose changes required.

## Verifying after merge + deploy

```bash
# On the host:
cd ~/honeybot
git pull
docker compose up -d --build

# Wait ~30s for ACME issuance + Open WebUI startup, then:
docker compose ps                       # all services Up
docker compose logs --tail=50 honeybot  # look for "api_server gateway started"
docker compose logs --tail=50 openwebui # look for "Application startup complete"
docker compose logs --tail=20 nginx     # no autossl errors

# In a browser:
curl -I https://honeybot.honeymanenterprises.com/    # 200 OK + open-webui headers
```

Then visit `https://honeybot.honeymanenterprises.com/` — first sign-up
becomes the local admin. After that, flip `ENABLE_SIGNUP=false` in
docker-compose.yml and `docker compose up -d openwebui` to lock down
account creation.
