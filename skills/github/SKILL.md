---
name: github
version: 0.1.0
description: Operate GitHub on behalf of the requesting Slack user via their personal access token.
triggers:
  - "github"
  - "gh issue"
  - "gh pr"
  - "my repos"
  - "my github"
capabilities:
  - gh_run
  - gh_connect
---

# GitHub Skill — v1 (per-user)

> **🔐 OTP Identity Gate**: Non-Slack sessions (Open WebUI, Discord, API)
> must complete email-based identity verification before accessing credentials.
> If `creds.sh` returns exit code 4, follow the OTP flow in the
> `otp-identity-verification` skill before retrying.

## Identity model

Per-user. PATs live at `op://Honeybot/GitHub-{SlackUserID}/token` and are
loaded into `GH_TOKEN` env only for the duration of a single `gh`
invocation.

This is **NOT** the same vault item the `honeybot-dev` skill uses. That
skill has its own bot-owned token (`op://Honeybot/GitHub Bot/token`) with
write access to exactly one repo (the honeybot repo itself). This skill is
for "let me do GitHub things on _my_ GitHub account".

## When to use

User-scoped GitHub operations: "list my open PRs", "create an issue in
honeyman/project-x", "check CI status on that branch". Anything that should
act _as the human who asked_.

## Connect flow (first-time per user)

1. User DMs: `connect github`
2. Bot DMs back:
   > Generate a fine-scoped PAT:
   > https://github.com/settings/personal-access-tokens/new
   >
   > Recommended scopes:
   > - Contents: Read
   > - Issues: Read and write
   > - Pull requests: Read and write
   > - Metadata: Read (automatic)
   >
   > Select which repos it can touch (don't give it "all repos" unless you
   > mean it). Paste the token here starting with `github_pat_` or `ghp_`.
3. Bot stores it:
   ```bash
   op item edit "GitHub-${SLACK_USER}" --vault Honeybot \
     token="$PAT"
   ```
   Creating the item if it doesn't exist.
4. Scrub. Verify with `gh auth status` using the new token.

## Per-request invocation pattern

```bash
export GH_TOKEN="$(../_lib/creds.sh GitHub token)"
gh "$@"
unset GH_TOKEN
```

`creds.sh` fails closed if no Slack user ID is present.

## Guardrails

- **Never** write the PAT to disk or log it.
- **Never** use one user's PAT to act on another user's behalf.
- Destructive ops (`gh repo delete`, `gh release delete`, force-push via
  `gh` flows) require Slack confirmation.
- Merging PRs: allowed for the requester's own PRs, but prompt with a
  preview of the change diff first.
