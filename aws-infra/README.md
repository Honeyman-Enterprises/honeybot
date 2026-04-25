# AWS infrastructure scripts

AWS resources for Honeybot, managed via AWS CLI instead of Terraform.
Each script is idempotent — running it twice leaves the same end state as
running it once. No state file. Uses the bot-level AWS creds from
`op://Honeybot/AWS/*` (resolved by 1Password's `op` CLI).

These scripts are **invoked from inside the `secrets-init` container** on
every `docker compose up`, via `scripts/ensure-aws-infra.sh`. They are
not meant to be run directly by a human anymore — the container does it
for you, automatically and idempotently.

TLS certs are issued and renewed in-process by **`lua-resty-acme`**
against Let's Encrypt (HTTP-01 challenge) inside the nginx/OpenResty
container — see `../nginx/`. No certbot binary, no sidecar, no cron, no
Route53 DNS-01 flow, no `/etc/letsencrypt` volume, and no AWS ACM wiring
(public ACM certs can't be exported anyway, and Private CA is ~$400/mo —
neither fits this topology).

Route53 records are managed manually in the AWS console:

- `honeybot.honeymanenterprises.com` → A record pointing at the EC2
  Elastic IP. Stable across stop/start; no automation needed.
- `hooks.honeybot.*` / `*.honeybot.*` CNAMEs → only added if/when Phase 2
  webhooks need them. Add directly in the console.

## Contents

| File                           | Purpose |
|--------------------------------|---------|
| `ebs-dlm-snapshot-policy.sh`   | Idempotent: creates or updates an EBS Data Lifecycle Manager policy that snapshots volumes tagged `Name=honeybot-docker-data` daily, retaining 7. Also creates the `AWSDataLifecycleManagerDefaultRole` IAM role on first run. |

The volume tagging itself (`Name=honeybot-docker-data` on the root EBS
volume of the `honeybot-prod`-tagged instance) is applied automatically
by `scripts/ensure-aws-infra.sh` on every secrets-init startup.

## How it runs

`docker compose up` triggers `secrets-init`, which runs (in order):

1. `seed-vault.sh`         — idempotent 1Password vault item creation
2. `emit-runtime-env.sh`   — writes `./.env.runtime` for ES + Neo4j
3. `ensure-aws-infra.sh`   — calls `ebs-dlm-snapshot-policy.sh` and
                             tags the root EBS volume

`ensure-aws-infra.sh` looks for an EC2 instance tagged
`Name=honeybot-prod` (override via `HONEYBOT_INSTANCE_TAG`). If none is
running — e.g. on a laptop — it exits 0 cleanly without touching AWS.

## Manual run (debugging only)

If you ever need to run the DLM policy script outside the container —
e.g. to debug a permissions issue from the EC2 host — you can:

```bash
# Pull AWS creds into the env first (varlock or `op read` work)
varlock run -- ./aws-infra/ebs-dlm-snapshot-policy.sh
```

This is rarely necessary and is **not** part of any standard workflow.
