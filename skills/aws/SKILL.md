---
name: aws
version: 0.1.0
description: Run AWS CLI commands on behalf of the requesting Slack user, using their personal IAM credentials from 1Password.
triggers:
  - "aws"
  - "s3"
  - "ec2"
  - "list my aws"
  - "show my aws"
capabilities:
  - aws_run
  - aws_connect
---

# AWS Skill — v1 (per-user IAM keys)

## Identity model

This skill is **strictly per-user**. When someone DMs "list my S3 buckets",
the skill reads IAM access keys from
`op://Honeybot/AWS-{SlackUserID}/{access_key_id,secret_access_key}` and runs
`aws` with those credentials in subprocess env only. Never cross-user, never
with bot-level creds. See `docs/identity-model.md`.

If the requester has not connected AWS yet, the skill offers to start the
`aws connect` flow — it does NOT fall back to any default account.

## When to use

Any Slack request that mentions AWS services, S3, EC2, Lambda, IAM, etc., by
the person asking about **their own** account. Cross-account requests
("Michelle, pull that S3 bucket for me") are out of scope for v1.

## Connect flow (first-time setup, per user)

1. User DMs: `connect aws`
2. Bot DMs back instructions:
   > Open the AWS Console → IAM → Users → your user → Security credentials →
   > Create access key. Choose "Command Line Interface (CLI)". Copy the
   > access key ID and secret, then paste them here in this DM on two lines:
   >
   > ```
   > AKIA...
   > secret-here
   > ```
3. When the user replies with two lines matching `AKIA[0-9A-Z]{16}` and a
   40-char secret:
   ```bash
   op item edit "AWS-${SLACK_USER}" --vault Honeybot \
     access_key_id="$AKID" secret_access_key="$SAK"
   ```
   (Create the item first with `op item create` if it doesn't exist.)
4. Scrub both values from working memory before continuing. Never echo.
5. Verify: run `aws sts get-caller-identity` with the new creds and report
   the ARN back to the user.

## Per-request invocation pattern

Every `aws` invocation MUST follow this pattern:

```bash
export AWS_ACCESS_KEY_ID="$(../_lib/creds.sh AWS access_key_id)"
export AWS_SECRET_ACCESS_KEY="$(../_lib/creds.sh AWS secret_access_key)"
export AWS_DEFAULT_REGION="$(../_lib/creds.sh AWS default_region || echo us-east-1)"
aws "$@"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

`creds.sh` refuses to run without `$HONEYBOT_SLACK_USER` set, so
misconfiguration fails closed.

## Guardrails

- **Never** write IAM keys to files on disk. Env vars only, unset after the
  call.
- **Never** echo keys back to Slack, even partially.
- **Never** use one user's keys to serve another user's request.
- Destructive operations (`delete`, `terminate`, `rm`, `--delete`) require a
  Slack confirmation block before execution. (Inherited convention from the
  HubSpot skill, applied here.)

## v2 roadmap

Replace long-lived IAM keys with AWS IAM Identity Center device-flow
(`aws sso login --use-device-code`). Same vault-per-user model, but creds
rotate automatically and scopes are enforced by SSO permission sets.
