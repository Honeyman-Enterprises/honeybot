# Phase 0: infrastructure expansion

Additive scaffolding for the Honeybot stack. No behavior change yet —
all new services start disabled or with unpopulated vault refs. Merging
this PR is safe: the existing `honeybot` container and `redeploy`
sidecar keep working unchanged.

## Architecture after merge

```
┌──────────────────────────────────────────────────────────────────────┐
│                              EC2                                      │
│                                                                       │
│   ┌───────────────┐                                                   │
│   │ nginx :80,443 │  TLS certs from AWS ACM (pulled at container     │
│   │ (TLS term +   │  start via instance IAM role — no certbot).      │
│   │  reverse prx) │                                                   │
│   └──────┬────────┘                                                   │
│          │ honeynet                                                   │
│   ┌──────▼────────┐   ┌───────────────┐   ┌───────────────┐          │
│   │   honeybot    │   │ elasticsearch │   │     neo4j     │          │
│   │ (hermes agent │   │  (internal)   │   │  (internal)   │          │
│   │  + slack GW)  │   └───────────────┘   └───────────────┘          │
│   └──────┬────────┘                                                   │
│          │                                                            │
│   ┌──────▼────────┐                                                   │
│   │   redeploy    │  polls origin/main, rebuilds + restarts           │
│   │   sidecar     │                                                   │
│   └───────────────┘                                                   │
│                                                                       │
│   Future (Phase 5+): mcp-mercury, mcp-image-ingest, mcp-proxy-memory │
└──────────────────────────────────────────────────────────────────────┘
```

## What's in this PR

### New services (docker-compose.yml)

- `secrets-init` — one-shot. Runs the honeybot image with an overridden
  entrypoint that invokes `seed-vault.sh` (creates any missing 1Password
  items) + `emit-runtime-env.sh` (writes `/repo/.env.runtime` on the host
  with values ES + Neo4j need). Exits 0; the other services gate on it
  via `depends_on: condition: service_completed_successfully`.
- `nginx` — TLS termination, reverse proxy. Listens 80/443 on host.
  Cert material comes from AWS ACM; wiring in `./nginx/Dockerfile`.
- `elasticsearch` — single-node, security enabled, internal network only.
  Consumes `ELASTIC_PASSWORD` from `.env.runtime` via `env_file:`.
- `neo4j` — community edition, auth enabled, internal network only.
  Consumes `NEO4J_AUTH` from `.env.runtime` via `env_file:`.

**Why `secrets-init` exists:** ES and Neo4j are upstream images that
don't know how to resolve `op://` refs. Compose's `env_file:` directive
needs a plain key=value file on the host. `secrets-init` is the
chicken-and-egg bridge: it runs first, reads from 1Password using the
service account token, and writes the host file those containers need.
The file is regenerated on every `docker compose up`, so rotating a
value in 1Password + re-running is the rotation workflow.

### New directories

- `nginx/` — Dockerfile + nginx.conf + conf.d/ with vhosts for
  `honeybot.honeymanenterprises.com` and `hooks.honeybot...`.
- `aws-infra/` — idempotent bash scripts for Route53 records + EBS DLM policy.
- `mcp/` — stub READMEs for Mercury, image-ingest, proxy-memory MCPs (Phase 5 + 8).

### Vault items

Every item referenced by `.env.schema` is created on demand by
`scripts/seed-vault.sh`, which runs inside the honeybot container on
every boot. Empty placeholders for human-filled credentials, auto-
generated passwords for internal services. No pre-merge 1Password work
is required beyond creating the `Honeybot` vault and a service account
token (see root `README.md` §1).

The seeded items that matter for Phase 1 bring-up:

| Item                        | Fields                                              | How populated          |
|-----------------------------|-----------------------------------------------------|------------------------|
| `Honeybot/Elasticsearch`    | password                                            | auto-generated on seed |
| `Honeybot/Neo4j`            | auth (format: user/password)                        | auto-generated on seed |
| `Honeybot/AWS`              | access_key_id, secret_access_key, default_region    | human fills in 1P UI   |
| `Honeybot/Anthropic API`    | api_key                                             | human fills in 1P UI   |
| `Honeybot/Mem0`             | key                                                 | human fills in 1P UI   |
| `Honeybot/Slack Bot`        | bot_token, app_token, signing_secret, allowed_user_ids | human fills in 1P UI |
| `Honeybot/HubSpot`          | personal_access_key                                 | filled via Slack flow  |
| `Honeybot/Exa`              | api_key (Phase 4)                                   | human fills in 1P UI   |
| `Honeybot/Brave Search`     | api_key (Phase 4)                                   | human fills in 1P UI   |
| `Honeybot/Tavily`           | api_key (Phase 4)                                   | human fills in 1P UI   |
| `Honeybot/Sentry`           | auth_token (Phase 4)                                | human fills in 1P UI   |
| `Honeybot/Fal`              | api_key (Phase 5)                                   | human fills in 1P UI   |
| `Honeybot/Mercury`          | api_token (Phase 5)                                 | human fills in 1P UI   |
| `Honeybot/Honcho`           | api_key, base_url (Phase 8)                         | human fills in 1P UI   |
| `Honeybot/Telegram`         | token (Phase 6)                                     | human fills in 1P UI   |

### Updated files

- `.env.schema` — vault refs for all of the above.
- `docker-compose.yml` — nginx + ES + neo4j service definitions, three new volumes.
- `README.md` — pointer to `docs/phase-0-infra.md`.

### What is NOT in this PR (future phases)

- ACM cert issuance + IAM role wiring for nginx to pull it (Phase 1).
- Hermes webhook platform enablement (Phase 2).
- Retell wiring (Phase 2).
- MCP server implementations (Phase 4 & 5).
- Memory proxy implementation (Phase 8).

## Pre-merge sanity

- [ ] `docker compose config` passes (validates the compose file)
- [ ] Existing `honeybot` service definition is unchanged (diff should
      only add services, volumes, not modify the honeybot block)
- [ ] `.env.schema` diff is additive — no existing vars modified
- [ ] New scripts have `chmod +x` set
- [ ] No secrets in the diff

## Post-merge, pre-Phase-1

1. Create the `Honeybot` vault in 1Password and a scoped service account
   (`honeybot-hermes-ec2`, `read_items` + `write_items`). Drop the token
   into `./op.env`.
2. `docker compose up -d --build honeybot` — the container's entrypoint
   runs `scripts/seed-vault.sh`, creating every vault item referenced
   by `.env.schema`. Internal secrets (ES, Neo4j) get auto-generated
   passwords on first creation; external-API items land as empty
   placeholders for humans to fill.
3. Fill in the real values for `Anthropic API`, `Mem0`, `Slack Bot`,
   and `AWS` in the 1Password UI. Varlock fails the container closed
   until these are populated.
4. Tail logs to confirm: `docker compose logs -f honeybot`.

Cert wiring (ACM → nginx) happens during Phase 1 bring-up; see
`docs/phase-1-bringup.md`.
