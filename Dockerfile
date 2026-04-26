# syntax=docker/dockerfile:1.7
#
# Honeybot \u2014 Hermes agent + Slack gateway + multi-skill runtime.
# Builds for both linux/amd64 and linux/arm64 (EC2 t4g.small is arm64).
#
# Pre-installed CLIs (see each section below for why):
#   - op       1Password CLI, reads per-user secrets at tool-invocation time
#   - varlock  resolves bot-level secrets at container start
#   - hs       HubSpot CLI
#   - aws      AWS CLI v2
#   - gcloud   Google Cloud CLI
#   - gam      GAM7, Google Workspace admin CLI
#   - slack    Official Slack CLI (Deno-based)
#   - gh       GitHub CLI (used by the honeybot-dev skill for self-PRs)
#
# Identity model: every credential representing a human is stored in 1Password
# at op://Honeybot/{Service}-{SlackUserID}/{field} and is only ever read using
# the Slack user ID of the person whose message we are currently processing.
# See docs/identity-model.md.
#
# Entrypoint: `varlock run --` resolves bot-level secrets (Anthropic, Slack
# bot/app tokens, OP service account token) from 1Password at container start,
# then execs `hermes gateway run`. No secrets live on disk inside the image.

FROM python:3.12-slim AS base

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# ---- System deps -----------------------------------------------------------
# - curl, unzip, xz-utils: fetch + extract CLI archives (op, AWS, GAM)
# - git: hermes install from source
# - ca-certificates, gnupg: TLS + NodeSource / Google apt keys
# - nodejs/npm: varlock CLI + @hubspot/cli (pre-installed below)
# - openssl: sign GitHub App JWTs (RS256) in skills/_lib/gh-app-token.sh
# - jq: parse the installation-token JSON response from the GitHub App flow
# - gosu: drop privileges from root in the secrets-init entrypoint. The op
#   CLI has two safety checks (CLI-side $HOME ownership walk + daemon-side
#   getpwuid lookup) that compose's `user:` directive can't satisfy on a
#   stock image; secrets-init starts as root, fixes both, then `exec gosu`
#   to the runtime UID. See scripts/secrets-init-entrypoint.sh.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl unzip xz-utils git ca-certificates gnupg openssl jq gosu \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# ---- 1Password CLI (op) ----------------------------------------------------
# Arch-aware: amd64 \u2192 x86_64 pkg; arm64 \u2192 aarch64 pkg.
# Version pinned; bump deliberately.
ARG OP_VERSION=2.30.3
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) OP_ARCH=amd64 ;; \
      arm64) OP_ARCH=arm64 ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -sSfL "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_${OP_ARCH}_v${OP_VERSION}.zip" -o /tmp/op.zip; \
    unzip /tmp/op.zip -d /usr/local/bin; \
    rm /tmp/op.zip; \
    op --version

# ---- Varlock + 1Password plugin -------------------------------------------
# Pin explicit versions \u2014 the unpinned `varlock` tag resolved to 0.0.2 during
# first build, which predates the `@plugin(...)` directive + `op()` resolver.
ARG VARLOCK_VERSION=0.9.0
ARG VARLOCK_OP_PLUGIN_VERSION=0.3.5
RUN npm install -g \
      "varlock@${VARLOCK_VERSION}" \
      "@varlock/1password-plugin@${VARLOCK_OP_PLUGIN_VERSION}" \
 && varlock --version

# ---- Hermes agent ----------------------------------------------------------
# Clone + editable install. Pin to a tag/SHA once we've verified one.
WORKDIR /opt
RUN git clone --depth=1 https://github.com/NousResearch/hermes-agent.git hermes \
 && cd hermes && pip install --no-cache-dir -e '.[slack]' \
 && python3 -c "import yaml, pathlib, subprocess, sys; \
deps = sorted({d for p in pathlib.Path('plugins').rglob('plugin.yaml') \
               for d in (yaml.safe_load(p.read_text()) or {}).get('pip_dependencies', []) or []}); \
print('Plugin pip deps:', deps); \
deps and subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--no-cache-dir', *deps])"

# ---- HubSpot CLI -----------------------------------------------------------
# Pre-installed globally as root so `honeybot` (non-root) can invoke `hs`
# without npm prefix dances. The skill's job is the auth flow, not the install.
# Version pin via ARG; bump deliberately.
ARG HUBSPOT_CLI_VERSION=7.7.0
RUN npm install -g "@hubspot/cli@${HUBSPOT_CLI_VERSION}" \
 && hs --version

# ---- AWS CLI v2 ------------------------------------------------------------
# Official AWS installer, arch-aware. Pinned for reproducibility; bump
# deliberately. Per-user IAM credentials are NOT baked in — the `aws` skill
# sets AWS_ACCESS_KEY_ID/SECRET env at invocation time from 1Password, keyed
# on the requesting Slack user's ID. See docs/identity-model.md.
ARG AWS_CLI_VERSION=2.17.0
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) AWS_ARCH=x86_64 ;; \
      arm64) AWS_ARCH=aarch64 ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -sSfL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWS_CLI_VERSION}.zip" -o /tmp/awscli.zip; \
    unzip -q /tmp/awscli.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/aws /tmp/awscli.zip; \
    aws --version

# ---- Google Cloud CLI (gcloud) ---------------------------------------------
# Google's apt repo supports both amd64 and arm64 as of 2023. Used by the
# `google-admin` skill alongside GAM. Per-user Gmail / Calendar access does
# NOT go through gcloud — it uses a small Python helper with the OAuth 2.0
# Device Authorization Grant (RFC 8628). gcloud here is for infra-side ops.
RUN install -d -m 0755 /usr/share/keyrings \
 && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends google-cloud-cli \
 && rm -rf /var/lib/apt/lists/* \
 && gcloud --version | head -n1

# ---- GAM (Google Workspace admin CLI) --------------------------------------
# GAM7 — community-maintained CLI for Workspace admin ops. Installed from
# official GitHub release tarballs (no interactive installer). Only the
# `google-admin` skill uses `gam`, gated by its own Slack-user allow-list,
# and backed by a service account at op://Honeybot/GoogleWorkspace Admin/.
# Debian 12 (bookworm, python:3.12-slim base) ships glibc 2.36, so we use the
# glibc2.35-compiled artifact (forward-compatible). If the base image ever
# moves to a newer glibc, bump GAM_GLIBC accordingly.
ARG GAM_VERSION=7.41.00
ARG GAM_GLIBC=glibc2.35
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) GAM_ARCH=x86_64 ;; \
      arm64) GAM_ARCH=arm64 ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/GAM-team/GAM/releases/download/v${GAM_VERSION}/gam-${GAM_VERSION}-linux-${GAM_ARCH}-${GAM_GLIBC}.tar.xz" \
      -o /tmp/gam.tar.xz; \
    mkdir -p /opt/gam7; \
    tar -xJf /tmp/gam.tar.xz -C /opt/gam7 --strip-components=1; \
    ln -sf /opt/gam7/gam /usr/local/bin/gam; \
    rm /tmp/gam.tar.xz; \
    gam version | head -n1

# ---- GitHub CLI (gh) -------------------------------------------------------
# Installed from GitHub's official apt repo (serves both amd64 and arm64).
# Used by the `honeybot-dev` skill to let the bot open PRs against its own
# repo. Authenticates at runtime via GH_TOKEN exported from 1Password at
# op://Honeybot/GitHub Bot/token. The bot NEVER merges PRs — humans do.
RUN install -d -m 0755 /usr/share/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && gh --version | head -n1

# ---- Slack CLI -------------------------------------------------------------
# Official Slack CLI (Deno-based) from downloads.slack-edge.com. Used by the
# `slack` skill. v1 of that skill uses the bot's own Slack credentials; a
# future v2 will support per-user xoxp tokens at op://Honeybot/Slack-{UID}/.
# The installer auto-detects arm64 vs x86_64.
RUN curl -fsSL https://downloads.slack-edge.com/slack-cli/install.sh \
      -o /tmp/slack-cli-install.sh \
 && bash /tmp/slack-cli-install.sh --skip-update </dev/null \
 && rm /tmp/slack-cli-install.sh \
 && slack --version | head -n1

# ---- Non-root runtime user -------------------------------------------------
# `useradd -m` on Debian (python:3.12-slim base) creates /home/honeybot with
# mode 0700 owned by 10001:10001. That's fine when the container runs as the
# baked `honeybot` UID, but the `secrets-init` compose service starts as
# root and `exec gosu`s to the host's ec2-user UID (1000 by default) so it
# can write to the bind-mounted /repo. After the gosu drop, UID 1000 needs
# to `cd /home/honeybot` to find seed-vault.sh / emit-runtime-env.sh /
# ensure-aws-infra.sh — without the traverse bit for "other", the chain
# would die with:
#   /bin/sh: cd: can't cd to /home/honeybot
#
# chmod 0755 makes the directory world-traversable. The seed/emit scripts
# inside are already COPY'd with --chmod=0755 (executable for any UID), and
# the .hermes/ subtree stays 10001-owned. The dropped UID's own $HOME
# during secrets-init is /home/secrets-init (created at runtime by the
# entrypoint script), NOT /home/honeybot — nothing op-related lands here.
RUN useradd -m -u 10001 -s /bin/bash honeybot \
 && chmod 0755 /home/honeybot
USER honeybot
WORKDIR /home/honeybot

# Hermes expects config + skills under $HOME/.hermes/ by default.
# workspace/ is where the honeybot-dev skill clones the bot's own repo so it
# can open PRs against itself. Isolated from .hermes/ intentionally.
RUN mkdir -p .hermes/config .hermes/skills .hermes/data workspace

# ---- Memory provider: Mem0 -------------------------------------------------
# Select Mem0 as the long-term memory backend. The API key itself is injected
# at container start via MEM0_API_KEY (resolved by Varlock from
# op://Honeybot/Mem0/key). We bake the *provider selection* into the image
# because the only persistent volume is .hermes/data — config written by
# `hermes config set` would otherwise be lost on every container recreation.
# Idempotent; safe across image rebuilds.
RUN hermes config set memory.provider mem0

# ---- Display: silence inter-tool commentary -------------------------------
# Hermes' default behavior on chat platforms is to surface the assistant's
# natural-language preamble between tool calls (e.g. "Let me check the
# config first.") as separate Slack messages — see
# gateway/stream_consumer.py::_send_commentary and gateway/run.py around the
# `interim_assistant_messages_enabled` resolution. The default is True, which
# spams the channel with "thinking out loud" lines that aren't the actual
# answer. Turning it off keeps the channel clean: only the final response
# (and tool-progress edits, if enabled) gets posted. The user can still see
# everything via `hermes logs`.
#
# Same write-to-config rationale as memory.provider above: only .hermes/data
# is volume-mounted, so config is baked in at image build time.
RUN hermes config set display.interim_assistant_messages false

# ---- Display: silence tool-progress notifications -------------------------
# Even with interim_assistant_messages=false, Hermes still emits per-tool
# progress lines (e.g. ":books: skill_view: \"gmail\"") to the chat surface
# via the tool_progress feed (see agent/display.py around line 950 for the
# emoji-prefix formatting, and gateway/run.py around 9350 for the resolution
# of the `tool_progress` config). Default is "all" — every tool call posts
# a separate Slack message — which is identical chat-noise to the old
# interim commentary, just emitted by a different code path.
#
# `off` silences the tool feed entirely; the final response is the only
# thing that lands in chat. The CLI / `hermes logs` still see everything.
# Other valid values: `new` (only on tool change), `all` (default), `verbose`.
#
# Same write-to-config rationale as the lines above: only .hermes/data is
# volume-mounted, so config written by `hermes config set` at runtime is
# wiped on every container recreate. Bake it into the image.
RUN hermes config set display.tool_progress off

COPY --chown=honeybot:honeybot skills/         ./.hermes/skills/
# Per-message gateway hooks. honeybot-identity in particular is load-bearing
# for the per-user identity model: it captures the requesting Slack user's
# ID from the agent:start event and writes it to a per-session sidecar file
# that skills/_lib/creds.sh reads. Without this hook installed in
# ~/.hermes/hooks/, every per-user skill (Gmail, AWS, HubSpot) fails closed.
COPY --chown=honeybot:honeybot hooks/          ./.hermes/hooks/
COPY --chown=honeybot:honeybot .env.schema     ./
COPY --chmod=0755 --chown=honeybot:honeybot scripts/seed-vault.sh        ./seed-vault.sh
# emit-runtime-env.sh writes /repo/.env.runtime from the `secrets-init`
# one-shot compose service (same image, different entrypoint). See
# docker-compose.yml for wiring.
COPY --chmod=0755 --chown=honeybot:honeybot scripts/emit-runtime-env.sh  ./emit-runtime-env.sh
# ensure-aws-infra.sh runs from secrets-init too. It calls into
# aws-infra/ebs-dlm-snapshot-policy.sh, so the whole aws-infra/ directory
# ships in the image. Both pieces are idempotent + skip cleanly when no
# honeybot-prod-tagged EC2 instance is found (laptop-safe).
COPY --chown=honeybot:honeybot aws-infra/                            ./aws-infra/
COPY --chmod=0755 --chown=honeybot:honeybot scripts/ensure-aws-infra.sh ./ensure-aws-infra.sh

# secrets-init's privilege-drop entrypoint. Lives at /usr/local/bin so it's
# on the default PATH and outside the honeybot user's home (which gets its
# perms massaged at runtime). Owned by root:root, mode 0755 — only the
# secrets-init compose service runs as root and invokes this; honeybot
# (UID 10001) can read+exec but not modify.
COPY --chmod=0755 scripts/secrets-init-entrypoint.sh /usr/local/bin/secrets-init-entrypoint.sh

# Varlock's autoDetectContextPath() reads process.env.PWD to locate
# .env.schema. Docker's WORKDIR sets cwd but doesn't export PWD, so we set
# it explicitly. Must match the directory containing .env.schema.
ENV PWD=/home/honeybot

# ---- Build provenance ------------------------------------------------------
# Baked into the image at build time so the running container can report
# exactly which commit it was built from. `pull-and-restart.sh` passes these
# as --build-arg on every rebuild; manual `docker compose build` falls back
# to "unknown" which is intentionally noisy.
#
# Surfaced via:
#   - HONEYBOT_GIT_SHA / HONEYBOT_GIT_BRANCH / HONEYBOT_BUILD_TIME env vars
#   - /home/honeybot/.hermes/build_info.json (machine-readable)
#   - the `version` skill (skills/version/bin/version.sh)
ARG GIT_SHA=unknown
ARG GIT_BRANCH=unknown
ARG BUILD_TIME=unknown
ENV HONEYBOT_GIT_SHA=$GIT_SHA \
    HONEYBOT_GIT_BRANCH=$GIT_BRANCH \
    HONEYBOT_BUILD_TIME=$BUILD_TIME
RUN printf '{"git_sha":"%s","git_branch":"%s","build_time":"%s"}\n' \
      "$GIT_SHA" "$GIT_BRANCH" "$BUILD_TIME" \
      > /home/honeybot/.hermes/build_info.json

# ---- Entrypoint ------------------------------------------------------------
# On every boot:
#   1. seed-vault.sh: idempotently ensure every 1Password item referenced
#      by .env.schema exists in the Honeybot vault. Uses the service
#      account token; no human signin or vault creation.
#   2. varlock run: read .env.schema, resolve op(...) via
#      OP_SERVICE_ACCOUNT_TOKEN, export validated env to the child.
#   3. hermes gateway: Slack Socket Mode front door.
# If seed-vault fails (vault unreachable, token bad), the container fails
# fast before varlock gets a chance to produce confusing error cascades.
# Use shell form so PWD stays in sync if anything cd's underneath us.
ENTRYPOINT ["/bin/bash", "-lc", "cd /home/honeybot && ./seed-vault.sh && exec varlock run -- \"$@\"", "--"]
CMD ["hermes", "gateway", "run", "--replace"]
