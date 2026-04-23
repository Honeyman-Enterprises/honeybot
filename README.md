# Honeybot

Slack-fronted [Hermes](https://github.com/NousResearch/hermes-agent) agent for
Michelle. Talks to Claude, installs CLIs on demand, starts with HubSpot.

- **LLM:** Anthropic Claude (via Hermes's Anthropic provider).
- **Front door:** Slack Socket Mode (outbound WebSocket; no open ports).
- **Secrets:** 1Password service account + [Varlock](https://github.com/dmno-dev/varlock).
- **Runtime:** Docker (identical image for laptop and EC2).
- **Host:** EC2 `t4g.small` (ARM / Graviton).
- **Public traffic:** OpenResty (nginx + LuaJIT), TLS terminated with Let's Encrypt certs issued + renewed in-process via [`lua-resty-acme`](https://github.com/fffonion/lua-resty-acme) (HTTP-01 challenge). No certbot, no sidecar, no cron. See [`docs/phase-0-infra.md`](docs/phase-0-infra.md).
- **Backing stores (Phase 0):** Elasticsearch + Neo4j, internal-only containers on the `honeynet` network. No ports published.

See [`async-wandering-marshmallow.md` plan](../..//.claude/plans/async-wandering-marshmallow.md)
for architectural context.

---

## Runbook

### 0. One-time developer setup (your laptop)

```bash
cd honeybot
./bootstrap/install-deps.sh      # docker check, op CLI, varlock, git hooks
git config core.hooksPath .githooks
```

### 1. 1Password vault + service account

One-time tasks in the 1Password web UI (no local `op signin` required):

1. **Create a vault** named `Honeybot`.
2. **Developer → Directory → Infrastructure Secrets Management → Create a
   Service Account** named `honeybot-hermes-ec2`. Scope: `Honeybot` vault
   only, permissions `read_items` + `write_items`.
3. Copy the `ops_...` token (shown once). Save it to your personal vault as
   "Honeybot Service Account Token".
4. Write the token to `./op.env` for local dev:
   ```bash
   echo "OP_SERVICE_ACCOUNT_TOKEN=ops_..." > op.env && chmod 600 op.env
   ```

That's it. On every container boot, `scripts/seed-vault.sh` (baked into the
image and invoked by the entrypoint) uses the service account token to
idempotently create any missing items in the `Honeybot` vault — empty
placeholders for human-filled credentials (Anthropic, Slack, Mem0, AWS,
HubSpot) and auto-generated passwords for internal services (Elasticsearch,
Neo4j). There is no host-side bootstrap to run and no human 1Password
signin anywhere in the flow.

After first boot, fill in the real values in the 1Password UI for:

- `Anthropic API / api_key`
- `Mem0 / key` (get one at <https://app.mem0.ai>)
- `Slack Bot` → `bot_token`, `app_token`, `signing_secret`, `allowed_user_ids`
- `AWS` → `access_key_id`, `secret_access_key` (region defaults to `us-east-1`)

Varlock fails the container closed until each `@required` item has a real
value, so the bot refuses to start with missing credentials by design.

Leave `HubSpot / personal_access_key` empty — the HubSpot skill fills it
at runtime when Michelle pastes her PAK in Slack.

### 2. Slack app

At <https://api.slack.com/apps>:

1. **Create New App → From scratch**, name it "Honeybot".
2. **Socket Mode → Enable**.
3. **OAuth & Permissions → Scopes (Bot Token)**: `chat:write`, `im:history`,
   `im:read`, `im:write`, `app_mentions:read`, `users:read`.
4. **Install to Workspace** → copy the `xoxb-...` bot token into the 1Password
   `Slack Bot / bot_token` field.
5. **Basic Information → App-Level Tokens → Generate** with scope
   `connections:write` → copy the `xapp-...` token into `Slack Bot / app_token`.
6. Get Michelle's Slack user ID (profile → more → "Copy member ID") → put in
   `Slack Bot / allowed_user_ids` (comma-separated if more than one).
7. Start a DM with the bot in Slack.

### 3. Local smoke test

```bash
docker compose up --build
# watch for: "Slack gateway connected (Socket Mode)"
```

DM "ping" to the bot in Slack. You should get a reply within a few seconds.

Two services come up: `honeybot` (the bot) and `redeploy` (the auto-updater
sidecar — polls origin/main and rebuilds when it moves; see
`redeploy/watch.sh`). For iterating locally you usually want the sidecar
out of the way:

```bash
docker compose up --build honeybot   # skip the sidecar while hacking
```

### 4. EC2 deployment

1. Launch `t4g.small`, Amazon Linux 2023 **arm64**, 20 GB gp3. Security group:
   inbound = SSH from your IP only; outbound = all.
2. Paste `bootstrap/ec2-userdata.sh` into the "User data" field on launch.
3. SSH (or SSM) in once:
   ```bash
   git clone https://github.com/Honeyman-Enterprises/honeybot.git ~/honeybot
   cd ~/honeybot
   echo "OP_SERVICE_ACCOUNT_TOKEN=ops_..." > op.env && chmod 600 op.env
   docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
   ```

   Same `./op.env` path and permissions as local dev — nothing special
   about prod. Gitignored, dockerignored, chmod 600, owned by `ec2-user`.

After that, merging a PR to `main` is the only action required to ship —
the `redeploy` sidecar handles pull + rebuild + restart within
`HONEYBOT_POLL_INTERVAL` seconds (default 120).

### 5. HubSpot v1 (install + auth)

In Slack, DM: **"install hubspot"**.

The bot will:
1. Install `@hubspot/cli` inside its container.
2. Ask you (as Michelle) for a Personal Access Key, linking you to
   <https://app.hubspot.com/l/personal-access-key>.
3. Store the key directly in 1Password (never on disk, never logged).
4. Run `hs auth` and confirm the portal name.

---

## Safety model

- The **only** plaintext secret on any host is `OP_SERVICE_ACCOUNT_TOKEN`,
  stored at `./op.env` in the repo root (same path in local dev and on
  EC2) with `chmod 600`, gitignored and dockerignored.
- All other secrets live in the 1Password `Honeybot` vault. Varlock resolves
  them at container start via `varlock run -- hermes gateway start`.
- The Slack gateway enforces an allowlist of user IDs (`SLACK_ALLOWED_USER_IDS`);
  unknown users are ignored.
- The pre-commit git hook blocks commits containing literal `ops_`, `sk-ant-`,
  `xoxb-`, or `xapp-` tokens, and runs `varlock scan` if installed.
- No inbound ports are exposed on the EC2 instance. Slack, Anthropic, HubSpot,
  and 1Password are all reached via outbound HTTPS / WSS.

## Directory layout

```
honeybot/
├── .env.schema              # Varlock schema (committed, no secret values)
├── .env.local.example       # template for developer overrides
├── Dockerfile               # multi-arch (amd64 + arm64) hermes image
├── docker-compose.yml       # base compose (honeybot + redeploy sidecar)
├── docker-compose.prod.yml  # prod overlay (restart policy only)
├── bootstrap/               # dev-machine and EC2 bootstrap scripts
├── hermes-config/           # hermes.toml, gateway.toml
├── redeploy/                # auto-updater sidecar (Dockerfile + watch.sh)
├── skills/
│   ├── _lib/                # gh-app-token.sh, creds.sh (shared helpers)
│   ├── honeybot-dev/        # self-edit-and-PR skill
│   └── hubspot/             # v1 install + auth skill
├── scripts/                 # seed-vault.sh (container-boot), pull-and-restart.sh, deploy.sh
├── docs/                    # github-app-setup.md, runbooks
└── .githooks/pre-commit     # secret-leak guard
```

## Roadmap

| Version | Scope                                                         |
|---------|---------------------------------------------------------------|
| v1      | HubSpot CLI install + auth via Slack DM                       |
| v2      | HubSpot CRM read (contacts, companies, deals)                 |
| v3      | HubSpot CRM write (create/update) with Slack confirmation UX  |
| v4      | HubSpot workflow / pipeline actions, gated by allowlist       |
| later   | Additional CLIs as Michelle needs them (same skill pattern)   |

## Open items (see plan, "Open Risks / Decisions to Revisit")

1. Verify Hermes config key names against the real `hermes-agent` repo on
   first container boot — adjust `hermes-config/*.toml` if needed.
2. Verify the skill manifest frontmatter format matches what Hermes actually
   reads (`~/.hermes/skills/`) — adjust `SKILL.md` if needed.
3. Confirm Hermes builds cleanly on `linux/arm64`; fall back to `t3.small`
   (x86) if not.
