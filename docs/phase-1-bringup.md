# Phase 1: bring up TLS + data containers + DNS automation

This phase takes the scaffolding from Phase 0 and actually lights it up
on the EC2. After Phase 1, the following are true:

- Route53 records for `honeybot.honeymanenterprises.com`,
  `hooks.honeybot.*`, and the wildcard all point at this EC2.
- The nginx container is terminating TLS on 443 using an **AWS ACM**
  cert pulled in at container start (no Let's Encrypt, no certbot, no
  Route53 DNS-01 flow).
- nginx is serving `/healthz` on both the apex and `hooks.honeybot.*`.
- Elasticsearch 8.15 is up with auth, internal-only.
- Neo4j 5.24 is up with auth, internal-only.
- AWS DLM is snapshotting the Docker data EBS volume daily with 7-day
  retention, once the volume is tagged `Name=honeybot-docker-data`.

## Prerequisites

1. PR #3 (Phase 0) merged to `main`.
2. On the EC2, `main` pulled: `git pull`.
3. 1Password `Honeybot` vault + service account set up (see root
   `README.md` §1). `op.env` present at the repo root with
   `OP_SERVICE_ACCOUNT_TOKEN=ops_...`. Vault item creation itself is
   handled in-container by `scripts/seed-vault.sh` on every boot —
   nothing to pre-create here.
4. Humans have filled in the `@required` items in 1Password that need
   real values: `Anthropic API`, `Mem0`, `Slack Bot`, and `AWS`. (The
   seeder creates them as empty placeholders; varlock fails the bot
   closed until they're populated.)
5. ACM cert issued for `honeybot.honeymanenterprises.com` (with the
   `*.honeybot.honeymanenterprises.com` SAN), in the same region as the
   EC2. The instance's IAM role needs `acm:ExportCertificate` for that
   cert ARN; wiring is in `./nginx/Dockerfile`.

## Run

From the EC2, in the repo root, with `op.env` present:

```bash
./scripts/phase-1-bringup.sh
```

The script is idempotent — if it fails mid-way, fix the cause and re-run.

## What it does

1. Preflight: verifies `op.env`, docker, compose, and the service
   account token loads. It does NOT probe for individual vault items;
   the `secrets-init` compose service seeds anything missing.
2. `docker compose build nginx honeybot`.
3. `aws-infra/route53-upsert.sh` — creates/updates the A + CNAME records.
4. `aws-infra/ebs-dlm-snapshot-policy.sh` — creates the DLM snapshot policy
   (you still need to tag the volume; see script output).
5. `docker compose up -d nginx honeybot elasticsearch neo4j` — compose
   orchestrates the order via `depends_on: service_completed_successfully`:
   - `secrets-init` runs FIRST. It seeds missing 1Password items and
     writes `./.env.runtime` (chmod 600) with `ELASTIC_PASSWORD` and
     `NEO4J_AUTH` read fresh from 1Password.
   - On exit 0, `elasticsearch`, `neo4j`, and `honeybot` start in
     parallel. ES and Neo4j consume `.env.runtime` via `env_file:`;
     honeybot resolves its own secrets inside the container via varlock.
   - If `secrets-init` fails (e.g. 1Password unreachable, token revoked),
     the dependent services never start — that's the intended fail-closed.
6. Runs healthchecks and reports status.

## Post-run

**No host-level crons.** If a recurring job is needed (Route53 IP
refresh after EC2 stop/start, ACM cert refresh, etc.), implement it as
a Hermes cron inside the `honeybot` container or as a dedicated sidecar
container. Never as a host crontab entry.

Tag the EBS data volume so the DLM policy actually snapshots it:

```bash
# Find the volume:
aws ec2 describe-volumes \
  --filters Name=attachment.instance-id,Values=<your-instance-id> \
  --query 'Volumes[].{Id:VolumeId,Size:Size,Device:Attachments[0].Device}' \
  --output table

# Tag it (the DLM policy targets Name=honeybot-docker-data):
aws ec2 create-tags \
  --resources vol-xxxxxxxx \
  --tags Key=Name,Value=honeybot-docker-data
```

First snapshot lands within 24h of tagging (schedule fires at 05:00 UTC).

## Verify end-to-end

From anywhere on the internet:

```bash
curl -v https://honeybot.honeymanenterprises.com/healthz
# Expect: 200, body "ok", valid ACM-issued cert

curl -v https://hooks.honeybot.honeymanenterprises.com/healthz
# Expect: 200, body "ok", same cert

curl -v https://anything.honeybot.honeymanenterprises.com/healthz
# Expect: 404 (vhost not configured) but valid cert — proves wildcard
```

Inside the container network (from the honeybot container):

```bash
curl -u "elastic:$(varlock get ELASTIC_PASSWORD)" http://elasticsearch:9200/_cluster/health
# Expect: JSON with status=green|yellow

nc -zv neo4j 7687
# Expect: connection succeeded
```

## Cost

| Resource | Monthly |
|----------|---------|
| Route53 hosted zone | ~$0.50 (already paid) |
| Route53 queries | <$0.01 at expected volume |
| ACM public cert | $0 (free for use on AWS-integrated services) |
| EBS snapshots (7 × 20GB delta avg) | ~$0.70 |
| Everything else | $0 |

## Next

Phase 2: enable Hermes webhook platform + wire Retell. No new costs.
