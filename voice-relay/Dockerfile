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
RUN useradd -m -u 10002 -s /usr/sbin/nologin voice \
 && chown -R voice:voice /app
USER voice

EXPOSE 8080

# Liveness: the /healthz route returns 200 once ingresses are mounted.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz').status==200 else 1)"

CMD ["python", "-m", "voice_relay"]
