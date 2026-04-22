# Phase 1: bring up TLS + data containers + DNS automation

This phase takes the scaffolding from Phase 0 and actually lights it up
on the EC2. After Phase 1, the following are true:

- Route53 records for `honeybot.honeymanenterprises.com`,
  `hooks.honeybot.*`, and the wildcard all point at this EC2.
- A daily cron re-upserts the records at 04:30 UTC so transient IP
  changes (we don't use Elastic IPs) heal themselves inside 24h.
- A valid Let's Encrypt production cert covers the apex + wildcard.
- nginx is terminating TLS on 443 and serving `/healthz` on both
  the apex and `hooks.honeybot.*`.
- Elasticsearch 8.15 is up with auth, internal-only.
- Neo4j 5.24 is up with auth, internal-only.
- AWS DLM is snapshotting the Docker data EBS volume daily with 7-day
  retention, once the volume is tagged `Name=honeybot-docker-data`.

## Prerequisites

1. PR #3 (Phase 0) merged to `main`.
2. On the EC2, `main` pulled: `git pull`.
3. 1Password vault items populated:
   | Item | Fields | How to generate |
   |------|--------|-----------------|
   | `Honeybot/Certbot`       | `email` | = `organization@honeymanenterprises.com` |
   | `Honeybot/Elasticsearch` | `password` | `openssl rand -base64 32` |
   | `Honeybot/Neo4j`         | `auth` | `printf 'neo4j/%s' "$(openssl rand -base64 32)"` |
4. Certbot IAM user created + creds filed in 1Password. Run this from
   your **laptop** (admin creds), NOT the EC2:
   ```bash
   cd honeybot
   ./aws-infra/bootstrap-certbot-iam.sh
   # File the printed AKID+secret into op://Honeybot/Certbot AWS/*
   ```

## Run

From the EC2, in the repo root, with `op.env` present:

```bash
./scripts/phase-1-bringup.sh
```

The script is idempotent — if it fails mid-way, fix the cause and re-run.

## What it does

1. Preflight: verifies `op.env`, docker, compose, varlock, and all
   required 1Password items are readable.
2. `docker compose build nginx certbot`.
3. `aws-infra/route53-upsert.sh` — creates/updates the A + CNAME records.
4. `aws-infra/ebs-dlm-snapshot-policy.sh` — creates the DLM snapshot policy
   (you still need to tag the volume; see script output).
5. Starts certbot against LE **staging** first, verifies cert issues.
6. Wipes the staging cert, starts certbot against LE **prod**, verifies
   a real cert lands.
7. Starts nginx, elasticsearch, neo4j.
8. Runs healthchecks and reports status.

## Post-run

Install the daily cron so DNS self-heals on EC2 restarts:

```bash
./scripts/install-phase-1-crons.sh
```

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
# Expect: 200, body "ok", valid cert (NOT the staging "Fake LE" CA)

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
| EBS snapshots (7 × 20GB delta avg) | ~$0.70 |
| Everything else | $0 |

## Next

Phase 2: enable Hermes webhook platform + wire Retell. No new costs.
