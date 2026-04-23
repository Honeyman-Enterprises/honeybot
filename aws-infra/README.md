# AWS infrastructure scripts

AWS resources for Honeybot, managed via AWS CLI instead of Terraform.
Each script is idempotent — running it twice leaves the same end state as
running it once. No state file. Uses the bot-level AWS creds from
`op://Honeybot/AWS/*` (resolved via varlock).

TLS certs are issued and renewed by **AWS ACM**, not certbot. There is
no dedicated IAM user, no Route53 DNS-01 flow, and no `/etc/letsencrypt`
volume anywhere in this repo.

## Contents

| File                           | Purpose |
|--------------------------------|---------|
| `route53-upsert.sh`            | Idempotent: creates/updates the A and CNAME records (honeybot + hooks + wildcard) pointing at the EC2 public IP (read from instance metadata). |
| `ebs-dlm-snapshot-policy.sh`   | One-time-ish: creates an EBS Data Lifecycle Manager policy that snapshots the Docker volume daily and expires snapshots after 7 days. |

## Run order (first time)

```bash
# 1. Seed Route53 records. Must be run from the EC2 itself so it can read
#    its own public IP. Uses the bot-level AWS creds.
varlock run -- ./aws-infra/route53-upsert.sh

# 2. Create the daily snapshot policy covering the Docker data volume.
#    Identify the volume ID first (see comments inside the script).
varlock run -- ./aws-infra/ebs-dlm-snapshot-policy.sh
```

## Re-running after IP change

EC2 without an Elastic IP will get a new public IP on stop/start.
Running `route53-upsert.sh` again is idempotent and will update the A
record to the new IP.

If a recurring refresh is needed, it MUST run inside a container (either
as a Hermes cron in the honeybot container or as a dedicated sidecar) —
not as a host-level crontab entry. See `docs/phase-1-bringup.md` for
context.
