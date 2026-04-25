# Phase 1: bring up TLS + data containers + AWS infra automation

This phase takes the Phase 0 scaffolding and lights it up on the EC2.
After Phase 1, the following are true:

- The nginx container is terminating TLS on 443 with **Let's Encrypt**
  certs issued + renewed in-process by `lua-resty-acme` over HTTP-01.
  No certbot binary, no sidecar, no cron, no DNS-01 flow. First
  handshake per whitelisted domain triggers issuance; renewals happen
  via a background timer inside the OpenResty worker.
- nginx is serving `/healthz` on `honeybot.honeymanenterprises.com`.
- Elasticsearch 8.15 is up with auth, internal-only.
- Neo4j 5.24 is up with auth, internal-only.
- AWS DLM is snapshotting the root EBS volume daily with 7-day
  retention. The root volume is auto-tagged `Name=honeybot-docker-data`
  by `secrets-init` on first run, so DLM picks it up immediately.

## Prerequisites

1. PR #3 (Phase 0) merged to `main`.
2. On the EC2, `main` pulled: `git pull`.
3. **EC2 instance tagged** `Name=honeybot-prod` (override via the
   `HONEYBOT_INSTANCE_TAG` env var if you want a different tag). Without
   this, `ensure-aws-infra.sh` no-ops and DLM has nothing to target.
4. **EIP allocated and associated** with the EC2 instance.
5. **Route53 records** managed manually in the AWS console:

   | Record | Type | Target | Notes |
   |--------|------|--------|-------|
   | `honeybot.honeymanenterprises.com` | A | EC2 EIP | Stable across stop/start |
   | `imessage.relay.honeybot.honeymanenterprises.com` | A | Home Mac public IP | Update when residential ISP rotates the IP. Used by Phase 9 iMessage relay (`ssh hermes-mac` from the EC2). DNS is the single point of truth so the EC2 doesn't need re-configuring on IP change. |
   | `hooks.honeybot.*` / `*.honeybot.*` | CNAME | apex | Add when Phase 2 webhooks ship |
6. **1Password** `Honeybot` vault + service account set up (see root
   `README.md` §1). `op.env` present at the repo root with
   `OP_SERVICE_ACCOUNT_TOKEN=ops_...`. Vault item creation is handled
   in-container by `scripts/seed-vault.sh` on every boot — nothing to
   pre-create here.
7. Humans have filled in the `@required` items in 1Password that need
   real values: `Anthropic API`, `Mem0`, `Slack Bot`, and `AWS`. (The
   seeder creates them as empty placeholders; varlock fails the bot
   closed until they're populated.)
8. **Port 80 reachable** from the public internet on the EIP. Let's
   Encrypt's HTTP-01 validators need to GET
   `http://<whitelisted-domain>/.well-known/acme-challenge/<token>`. If
   the Security Group blocks inbound :80, issuance silently fails and
   nginx keeps serving the self-signed bootstrap cert. No AWS cert or
   IAM role permissions are required — LE is entirely out-of-band of AWS.
9. (Optional) `ACME_ACCOUNT_EMAIL` overridden in the environment if you
   want LE expiry notices to go somewhere other than the default
   `ops@honeymanenterprises.com`.

## Run

From the EC2, in the repo root, with `op.env` present:

```bash
./scripts/phase-1-bringup.sh
```

Or, equivalently:

```bash
docker compose up -d --build
```

The bring-up script is now a thin wrapper: preflight + `compose up` +
healthchecks. Everything else (vault seeding, runtime env, AWS-side DLM
policy, root-volume tagging) is handled inside the `secrets-init`
one-shot container, which runs first by virtue of `depends_on`.

## What `secrets-init` actually does

Compose runs `secrets-init` BEFORE nginx/honeybot/elasticsearch/neo4j
via `depends_on: condition: service_completed_successfully`. The
container's entrypoint chains three idempotent scripts:

1. **`seed-vault.sh`** — Creates any missing 1Password items in the
   `Honeybot` vault. Empty placeholders for human-filled creds;
   auto-generated passwords for internal services (Elasticsearch,
   Neo4j).
2. **`emit-runtime-env.sh`** — Writes `./.env.runtime` (chmod 600) with
   `ELASTIC_PASSWORD` and `NEO4J_AUTH` read fresh from 1Password. ES
   and Neo4j consume this via `env_file:`.
3. **`ensure-aws-infra.sh`** — Pulls AWS creds from
   `op://Honeybot/AWS/*`, finds the running EC2 instance tagged
   `Name=honeybot-prod`, then:
   - Runs `aws-infra/ebs-dlm-snapshot-policy.sh` (creates the DLM IAM
     role if missing, upserts the policy by description).
   - Tags the root EBS volume `Name=honeybot-docker-data` if not
     already tagged, so DLM actually targets it.

If `ensure-aws-infra.sh` finds no instance tagged `Name=honeybot-prod`
(laptop dev, or you forgot to tag the EC2), it logs that and exits 0
cleanly. The rest of the stack still comes up; DLM just won't have
anything to snapshot.

If `secrets-init` fails (1Password unreachable, token revoked, AWS
creds missing/wrong, etc.), the dependent services never start. That's
the intended fail-closed.

## Post-run

**No host-level crons.** Cert renewal happens in-process via
`lua-resty-acme`'s background timer, 30 days before expiry. Route53 IP
refresh is not needed — the EC2 has an EIP. DLM snapshots are scheduled
inside AWS. Any recurring app-level work runs inside a container —
either as a Hermes cron in the honeybot container or a dedicated
sidecar. Never as a host crontab entry.

## Verify end-to-end

From anywhere on the internet:

```bash
curl -v https://honeybot.honeymanenterprises.com/healthz
# Expect: 200, body "ok", valid Let's Encrypt cert (first request may
# stall 2-5s while lua-resty-acme completes HTTP-01 issuance)
```

If/when Phase 2 adds the hooks subdomain:

```bash
curl -v https://hooks.honeybot.honeymanenterprises.com/healthz
# Expect: 200, body "ok", separate LE cert (one per whitelisted SNI)

curl -v https://anything.honeybot.honeymanenterprises.com/healthz
# Expect: TLS handshake completes with the bootstrap self-signed cert
# (CN=bootstrap.invalid) because `anything.*` is NOT in the autossl
# whitelist — lua-resty-acme refuses to issue for unlisted SNIs. This
# is the safety rail against attackers pointing their own domain at us.
```

Inside the container network (from the honeybot container):

```bash
curl -u "elastic:$(varlock get ELASTIC_PASSWORD)" http://elasticsearch:9200/_cluster/health
# Expect: JSON with status=green|yellow

nc -zv neo4j 7687
# Expect: connection succeeded
```

Verify AWS-side ensure ran:

```bash
docker compose logs secrets-init | grep ensure-aws-infra
# Expect: lines about finding the instance, ensuring DLM policy, and
# tagging the root volume (or "already tagged ... no-op" on re-runs).

aws ec2 describe-tags \
  --filters "Name=key,Values=Name" "Name=resource-type,Values=volume" \
  --query 'Tags[?Value==`honeybot-docker-data`]'
# Expect: one entry, the root volume of the honeybot-prod instance.
```

## Troubleshooting

### `git fetch` / `git pull` on the EC2 fails with permission errors

Symptoms on the EC2 host shell, any of:

```
error: insufficient permission for adding an object to repository database .git/objects
fatal: failed to write object
fatal: unpack-objects failed
```

```
error: unable to unlink old 'path/to/file': Permission denied
```

Cause: an earlier version of the `redeploy` sidecar ran as `root` (the
default for the `docker:cli` base image) with the host repo bind-
mounted into the container. Two consequences:

- `git fetch` from inside the sidecar wrote **root-owned blobs into
  `.git/objects/`**, blocking later writes by ec2-user.
- `git reset --hard origin/main` from inside the sidecar **rewrote
  working-tree files as root**, blocking later `git pull` from
  unlinking them.

So both `.git/` and the working tree may be poisoned. The chown
recovery has to cover the whole repo, not just `.git`:

```bash
cd ~/honeybot
sudo chown -R ec2-user:ec2-user .
```

After that, `git pull` works again, and the new `redeploy` sidecar
config (runs as UID 1000 / GID 1000 with `group_add` for the docker
socket — see `docker-compose.yml`) prevents recurrence.

If your EC2 isn't Amazon Linux 2023 (ec2-user is not 1000:1000, or
docker group GID isn't 988), set the override env vars before
`docker compose up`:

```bash
export HONEYBOT_HOST_UID=$(id -u ec2-user 2>/dev/null || id -u)
export HONEYBOT_HOST_GID=$(id -g ec2-user 2>/dev/null || id -g)
export HONEYBOT_DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
docker compose up -d
```

## Cost

| Resource | Monthly |
|----------|---------|
| Route53 hosted zone | ~$0.50 (already paid) |
| Route53 queries | <$0.01 at expected volume |
| Let's Encrypt certs | $0 (free, rate limit: 50 certs/week/domain) |
| EBS snapshots (7 × 20GB delta avg) | ~$0.70 |
| Everything else | $0 |

## Next

Phase 2: Hermes webhook platform. (Retell wiring is sidelined indefinitely
— Retell's service is down.)
