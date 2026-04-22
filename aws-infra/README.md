# AWS infrastructure scripts

AWS resources for Honeybot, managed via AWS CLI instead of Terraform.
Each script is idempotent — running it twice leaves the same end state as
running it once. No state file. Uses the bot-level AWS creds from
`op://Honeybot/AWS/*` (resolved via varlock), except for the certbot IAM
user bootstrap which is run once as a human from your laptop.

## Contents

| File                           | Purpose |
|--------------------------------|---------|
| `iam-certbot-policy.json`      | Scoped-down IAM policy for certbot — allows only Route53 record changes on the honeymanenterprises.com hosted zone. |
| `bootstrap-certbot-iam.sh`     | One-time: creates the `honeybot-certbot` IAM user, attaches the policy, emits access keys, prompts you to file them in 1Password. |
| `route53-upsert.sh`            | Idempotent: creates/updates the A and CNAME records (honeybot + hooks + wildcard) pointing at the EC2 public IP (read from instance metadata). |
| `ebs-dlm-snapshot-policy.sh`   | One-time-ish: creates an EBS Data Lifecycle Manager policy that snapshots the Docker volume daily and expires snapshots after 7 days. |

## Run order (first time)

```bash
# 1. Create the scoped IAM user for certbot (run as a human, with admin creds).
./aws-infra/bootstrap-certbot-iam.sh
# → Prints access key ID + secret. File into 1Password at
#   op://Honeybot/Certbot AWS/{access_key_id,secret_access_key,default_region}.

# 2. Seed Route53 records. Must be run from the EC2 itself so it can read
#    its own public IP. Uses the bot-level AWS creds.
varlock run -- ./aws-infra/route53-upsert.sh

# 3. Create the daily snapshot policy covering the Docker data volume.
#    Identify the volume ID first (see comments inside the script).
varlock run -- ./aws-infra/ebs-dlm-snapshot-policy.sh
```

## Re-running after IP change

EC2 without an Elastic IP will get a new public IP on stop/start.
Running `route53-upsert.sh` again is idempotent and will update the A
record to the new IP. A cron job (set up in Phase 1) runs this every
24h as a belt-and-suspenders.
