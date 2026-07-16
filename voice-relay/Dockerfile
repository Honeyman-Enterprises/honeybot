# syntax=docker/dockerfile:1.7
#
# voice-relay — thin sidecar that bridges voice assistants (Siri, Claude
# voice, ChatGPT voice) to honeybot. See docs/voice-relay.md.
#
# Multi-arch (amd64 + arm64) via the stdlib-only + pip wheels below; no
# arch-specific binaries. Runs as a non-root user, no secrets baked in —
# token map / Slack token / api_server key arrive at runtime via env
# (.env.runtime, emitted by the secrets-init compose service).

FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY voice_relay/ ./voice_relay/

# Non-root runtime user (distinct UID from honeybot's 10001).
#
# NB: python:3.12-slim (debian bookworm-slim) does NOT ship the `passwd`
# package (priority "important" — slim keeps only "required"), so `useradd`
# isn't available and we don't want to apt-install it just for one service
# account. Append the user/group to /etc/passwd + /etc/group directly:
# deterministic, dependency-free, and all this service needs. Home is /app
# (already exists, chowned below); shell is nologin because the container
# only ever runs `python -m voice_relay`, never a login shell.
#
# /data holds the live token map pushed by honeybot's voice-token skill
# (VOICE_TOKEN_STORE_PATH). Pre-create it owned by voice (10002) so a fresh
# named volume inherits that ownership (Docker copies the image dir's
# ownership onto an empty volume — the same rule that bit .hermes/state).
RUN echo 'voice:x:10002:10002::/app:/usr/sbin/nologin' >> /etc/passwd \
 && echo 'voice:x:10002:' >> /etc/group \
 && mkdir -p /data \
 && chown -R 10002:10002 /app /data
USER voice

EXPOSE 8080

# Liveness: the /healthz route returns 200 once ingresses are mounted.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz').status==200 else 1)"

CMD ["python", "-m", "voice_relay"]
