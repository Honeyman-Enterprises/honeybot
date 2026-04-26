---
name: version
version: 0.1.0
description: Report the running honeybot's build provenance — git SHA, branch, build time, container uptime — and compare it against the latest commit on origin/main. Use this whenever a user asks "what version are you" or "did the redeploy work".
triggers:
  - "what version"
  - "what version are you"
  - "did the redeploy work"
  - "are you up to date"
  - "what commit"
  - "honeybot version"
  - "show your version"
capabilities:
  - version_show
---

# Version Skill — running build provenance

## What this is

Tells the user (and the agent itself) exactly which git commit the running
honeybot was built from, when, and how that compares to whatever
`origin/main` is right now. Solves the "how do I know my redeploy actually
landed" problem reported in Slack on 2026-04-26.

## How it works

At image build time, the Dockerfile bakes three values into the image:

- `HONEYBOT_GIT_SHA` — the full commit SHA the image was built from
- `HONEYBOT_GIT_BRANCH` — the branch (default `main`)
- `HONEYBOT_BUILD_TIME` — UTC timestamp of the build

These come from `--build-arg` flags passed by `scripts/pull-and-restart.sh`
on every redeploy. Manual `docker compose build` without args produces
`unknown` — that's intentionally noisy so we notice un-tracked builds.

A copy of the same data is also at `/home/honeybot/.hermes/build_info.json`
for any caller that prefers a file over env.

## Usage

```bash
./skills/version/bin/version.sh
```

Output (pretty):

```
honeybot version
  commit:    ac3713a (origin/main: ac3713a) ✓ up to date
  branch:    main
  built:     2026-04-26T03:12:45Z
  container: started 2026-04-26T02:45:03Z (uptime 0d 0h 28m)
```

Output (with `--json`):

```json
{
  "running": {
    "git_sha": "ac3713a...",
    "git_branch": "main",
    "build_time": "2026-04-26T03:12:45Z",
    "container_started": "2026-04-26T02:45:03Z",
    "uptime_seconds": 1680
  },
  "remote": {
    "git_sha": "ac3713a...",
    "branch": "main"
  },
  "up_to_date": true,
  "commits_behind": 0
}
```

If the running image is behind origin/main (i.e. a merge happened but the
redeploy hasn't cycled yet), `up_to_date` is `false` and `commits_behind`
shows how far. The agent should surface that to the user clearly.

## When the agent should run this skill

- User asks "what version are you on" / "are you up to date" / "did the
  redeploy work"
- After the agent merges its own PR (via `honeybot-dev`), to confirm the
  redeploy actually landed — poll once after a few minutes, surface
  the result back to the user.
- Anytime the bot's behavior seems inconsistent with the latest source.

## Failure modes

- **Build args were `unknown`** (manual build skipped them) → skill reports
  `git_sha: unknown` honestly. Suggests running `pull-and-restart.sh`.
- **No network for `git ls-remote`** → skill still reports running info,
  marks `remote: null` and `up_to_date: null` (unknown).
- **`/home/honeybot/.hermes/build_info.json` missing** → falls back to
  the env vars; if those are also missing, reports everything as unknown.
