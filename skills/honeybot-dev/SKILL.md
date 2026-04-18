---
name: honeybot-dev
version: 0.1.0
description: Let Hermes modify its own source tree by opening a pull request against the honeybot GitHub repo. The bot never merges — humans do.
triggers:
  - "update yourself"
  - "edit your code"
  - "add a skill"
  - "fix your"
  - "modify your"
  - "open a pr on yourself"
capabilities:
  - honeybot_workspace_init
  - honeybot_branch
  - honeybot_commit_pr
  - honeybot_status
---

# Honeybot-Dev Skill — bot modifies its own code

## What this is

This is the skill that lets you ask the bot to improve itself: "add a skill
for Linear", "fix the typo in the HubSpot SKILL.md", "bump the AWS CLI
version". The bot clones its own GitHub repo into a workspace, makes the
edits, opens a pull request, and reports the URL back. It **never merges**.

It does **not** redeploy itself. Redeploy happens when:
1. A human reviews and merges the PR on GitHub.
2. The `publish-image` workflow builds and pushes a new image to ghcr.io.
3. Watchtower (running alongside the bot) detects the new image digest and
   restarts the container.

Three separate gates. The bot's authority ends at "PR opened".

## Identity model

This skill is an exception to the per-user pattern. It acts as a dedicated
GitHub identity — call it `honeybot-bot` — with a fine-scoped PAT or
GitHub App installation that has `contents:write` + `pull_requests:write`
on exactly one repo: the honeybot repo itself.

Token location:

```
op://Honeybot/GitHub Bot/token
```

Commit identity:

```
user.name  = Honeybot
user.email = honeybot@noreply.honeymanenterprises.com
```

(Configured at workspace init, not baked in the image.)

## Authorization

Not every Slack user should be able to rewrite the bot. Gate this skill on
an allow-list stored at:

```
op://Honeybot/GitHub Bot/dev_slack_users   # comma-separated Slack UIDs
```

Before doing anything, check `$HONEYBOT_SLACK_USER` is in that list. If
not, refuse:

> Modifying the bot's own code is restricted to the Honeybot dev allow-list.
> You're not on it. If this is a mistake, talk to whoever owns the
> Honeybot/GitHub Bot vault item.

## Workspace location

```
/home/honeybot/workspace/honeybot
```

This is mounted as a Docker named volume (`hermes-workspace`) in
docker-compose, so branches survive container restarts. The workspace is
NOT the image's source tree — it's a full clone the bot reads and writes.

## Required environment

- `HONEYBOT_REPO_SLUG` — e.g. `honeyman/honeybot`. Set in docker-compose.
- `HONEYBOT_DEV_BASE_BRANCH` — default `main`. Set in docker-compose.
- `HONEYBOT_SLACK_USER` — the requesting user's Slack ID (injected by
  Hermes / LLM; see identity-model.md).

## Flow

### 0. On every invocation: ensure workspace is ready

```bash
./bin/init-workspace.sh
```

Idempotent. Clones if missing, fetches + fast-forwards `main` if present,
exports `GH_TOKEN` from vault, configures `git` identity. Fails closed if
the dev allow-list check fails.

### 1. Start a branch

```bash
./bin/start-branch.sh <slug>
```

- Slug must match `[a-z0-9][a-z0-9-]{1,50}` — no slashes, no spaces.
- Full branch name becomes `claude/<slug>`.
- Refuses if the branch already exists remotely (use a different slug —
  don't silently resume stale work).
- Refuses if `<slug>` starts with `main` or `master`.

### 2. Make edits

Use the standard shell / file-edit tools inside the workspace. Touch
whatever files the request needs. Don't rewrite everything — keep the
diff minimal and reviewable.

### 3. Commit + push + open PR

```bash
./bin/open-pr.sh "<title>" "<body>"
```

- Stages all changes, commits with the provided title + body, pushes the
  branch, opens a PR against `$HONEYBOT_DEV_BASE_BRANCH`.
- Refuses if on `main` / `master`.
- Refuses if branch doesn't start with `claude/`.
- Refuses if there are no changes to commit.
- On success: prints the PR URL to stdout — relay it to the Slack user.

### 4. If something goes wrong

```bash
./bin/abort.sh
```

- `git reset --hard` + `git checkout main` + deletes the local branch.
- Does NOT delete remote branches (in case a PR was already opened).
- Use when the bot realizes mid-stream it's heading the wrong direction.

## Guardrails — non-negotiable

- **Never push to `main` / `master`.** Scripts refuse; the bot refuses.
- **Never merge PRs.** `gh pr merge` is not called anywhere in this skill.
- **Never force-push.** If a branch gets messy, abort and start a fresh
  branch with a new slug.
- **Never bypass the allow-list.** No env override, no "admin mode" flag.
- **Never commit secrets.** The repo's `.githooks/pre-commit` scans for
  known token patterns and aborts. If the bot's commit is rejected by the
  hook, it surfaces the error to the user and stops — does not retry
  with `--no-verify`.
- **Never touch `.github/workflows/` without explicit user approval.**
  Modifying CI is a privilege escalation vector; prompt for confirmation
  via Slack before touching those files.

## Example

User DMs: "add a skill that wraps the `jq` CLI"

Bot reasons, then runs:

```bash
cd ~/workspace/honeybot
./skills/honeybot-dev/bin/init-workspace.sh
./skills/honeybot-dev/bin/start-branch.sh add-jq-skill
mkdir -p skills/jq
cat > skills/jq/SKILL.md <<'EOF'
...
EOF
./skills/honeybot-dev/bin/open-pr.sh \
  "add jq skill" \
  "Adds a thin skill wrapping the jq CLI for ad-hoc JSON operations."
```

Reports: "Opened PR #47: https://github.com/honeyman/honeybot/pull/47 — ready for review."

## Out of scope for v1

- Opening PRs against any repo other than the bot's own.
- Reviewing or merging PRs.
- Rebasing / squashing history.
- Cherry-picking across branches.
- Anything involving submodules.
