# AWS infrastructure scripts

AWS resources for Honeybot, managed via AWS CLI instead of Terraform.
Each script is idempotent — running it twice leaves the same end state as
running it once. No state file. Uses the bot-level AWS creds from
`op://Honeybot/AWS/*` (resolved via varlock).

TLS certs are issued and renewed in-process by **`lua-resty-acme`**
against Let's Encrypt (HTTP-01 challenge) inside the nginx/OpenResty
container — see `../nginx/`. No certbot binary, no sidecar, no cron,
no Route53 DNS-01 flow, no `/etc/letsencrypt` volume, and no AWS ACM
wiring (public ACM certs can't be exported anyway, and Private CA is
~$400/mo — neither fits this topology). The scripts here cover only
Route53 A/CNAME records and EBS snapshot lifecycle.

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

The EC2 has an **Elastic IP**, so the public IP is stable across
stop/start and Route53 records normally don't need to be touched after
the initial upsert. If the EIP is ever replaced, re-running
`route53-upsert.sh` is idempotent and will update the A record to the
new IP.

If a recurring refresh is ever needed, it MUST run inside a container
(either as a Hermes cron in the honeybot container or as a dedicated
sidecar) — not as a host-level crontab entry. See
`docs/phase-1-bringup.md` for context.
