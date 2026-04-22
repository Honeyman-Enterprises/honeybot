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
│   ┌───────────────┐   ┌───────────────┐                              │
│   │ nginx :80,443 │◄──┤   certbot     │                              │
│   │ (TLS term +   │   │  (LE wildcard │                              │
│   │  reverse prx) │   │   via R53)    │                              │
│   └──────┬────────┘   └───────────────┘                              │
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

- `nginx` — TLS termination, reverse proxy. Listens 80/443 on host.
- `certbot` — LE wildcard cert via Route53 DNS-01, auto-renewal loop.
- `elasticsearch` — single-node, security enabled, internal network only.
- `neo4j` — community edition, auth enabled, internal network only.

### New directories

- `nginx/` — Dockerfile + nginx.conf + conf.d/ with vhosts for
  `honeybot.honeymanenterprises.com` and `hooks.honeybot...`.
- `certbot/` — Dockerfile + entrypoint.sh (issue + renew loop) + renew.sh (deploy hook).
- `aws-infra/` — idempotent bash scripts for IAM (certbot), Route53 records, EBS DLM policy.
- `mcp/` — stub READMEs for Mercury, image-ingest, proxy-memory MCPs (Phase 5 + 8).

### New vault items (to be populated in 1Password before Phase 1)

| Item                        | Fields                                              |
|-----------------------------|-----------------------------------------------------|
| `Honeybot/Certbot AWS`      | access_key_id, secret_access_key, default_region    |
| `Honeybot/Certbot`          | email                                               |
| `Honeybot/Elasticsearch`    | password                                            |
| `Honeybot/Neo4j`            | auth (format: user/password)                        |
| `Honeybot/Exa`              | api_key (Phase 4)                                   |
| `Honeybot/Brave Search`     | api_key (Phase 4)                                   |
| `Honeybot/Tavily`           | api_key (Phase 4)                                   |
| `Honeybot/Sentry`           | auth_token (Phase 4)                                |
| `Honeybot/Fal`              | api_key (Phase 5)                                   |
| `Honeybot/Mercury`          | api_token (Phase 5)                                 |
| `Honeybot/Honcho`           | api_key, base_url (Phase 8)                         |

`Honeybot/Telegram` already has `token` filed (Phase 6).

### Updated files

- `.env.schema` — new vault refs for all of the above.
- `docker-compose.yml` — four new service definitions + six new volumes.
- `README.md` — pointer to `docs/phase-0-infra.md`.

### What is NOT in this PR (future phases)

- Actual issuance of the LE cert (Phase 1 — run `aws-infra/bootstrap-certbot-iam.sh` and `route53-upsert.sh` first).
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

1. Populate the new 1Password items (see table above — at minimum, the
   Certbot AWS creds via `aws-infra/bootstrap-certbot-iam.sh`, the
   Certbot email, the Elasticsearch password, and Neo4j auth).
2. Generate strong random passwords for ES + Neo4j:
   ```bash
   openssl rand -base64 32     # good default
   ```
3. On EC2: `git pull && docker compose up -d --build nginx certbot elasticsearch neo4j`
4. Tail logs to confirm: `docker compose logs -f certbot elasticsearch neo4j`

Certbot will fail fast if the Route53 creds aren't set — that's fine,
Phase 1 runs the bootstrap. Until then, it'll restart-loop at the
"resolved env" stage.
