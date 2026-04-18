# Honeybot

Slack-fronted [Hermes](https://github.com/NousResearch/hermes-agent) agent for
Michelle. Talks to Claude, installs CLIs on demand, starts with HubSpot.

- **LLM:** Anthropic Claude (via Hermes's Anthropic provider).
- **Front door:** Slack Socket Mode (outbound WebSocket; no open ports).
- **Secrets:** 1Password service account + [Varlock](https://github.com/dmno-dev/varlock).
- **Runtime:** Docker (identical image for laptop and EC2).
- **Host:** EC2 `t4g.small` (ARM / Graviton).

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

```bash
eval $(op signin)                # sign in as your human user
./scripts/op-bootstrap.sh        # creates "Honeybot" vault + seed items
```

Then in the 1Password web UI:

1. Fill in real values for `Anthropic API / api_key` and the `Slack Bot`
   fields (`bot_token`, `app_token`, `signing_secret`, `allowed_user_ids`).
2. **Developer → Directory → Infrastructure Secrets Management → Create a
   Service Account** named `honeybot-hermes-ec2`. Scope: `Honeybot` vault
   only, permissions `read_items` + `write_items`.
3. Copy the `ops_...` token (shown once). Save it to your personal vault as
   "Honeybot Service Account Token".
4. Write the token to `./op.env` for local dev:
   ```bash
   echo "OP_SERVICE_ACCOUNT_TOKEN=ops_..." > op.env && chmod 600 op.env
   ```

Leave the `HubSpot / personal_access_key` field empty — the HubSpot skill
fills it at runtime when Michelle pastes her PAK in Slack.

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

### 4. EC2 deployment

1. Launch `t4g.small`, Amazon Linux 2023 **arm64**, 20 GB gp3. Security group:
   inbound = SSH from your IP only; outbound = all.
2. Paste `bootstrap/ec2-userdata.sh` into the "User data" field on launch.
3. SSH in once:
   ```bash
   echo "OP_SERVICE_ACCOUNT_TOKEN=ops_..." | sudo tee /etc/honeybot/op.env
   sudo chown ec2-user:ec2-user /etc/honeybot/op.env
   sudo chmod 600 /etc/honeybot/op.env
   ```
4. From your laptop:
   ```bash
   HONEYBOT_HOST=ec2-xx-xx-xx-xx.compute.amazonaws.com ./scripts/deploy.sh
   ```

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
  stored at `./op.env` (local) or `/etc/honeybot/op.env` (EC2) with `chmod 600`.
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
├── Dockerfile               # multi-arch (amd64 + arm64) image
├── docker-compose.yml       # base compose (local + prod)
├── docker-compose.prod.yml  # prod overlay (uses /etc/honeybot/op.env)
├── bootstrap/               # dev-machine and EC2 bootstrap scripts
├── hermes-config/           # hermes.toml, gateway.toml
├── skills/
│   └── hubspot/             # v1 install + auth skill
├── scripts/                 # op-bootstrap.sh, deploy.sh
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
