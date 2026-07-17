# syntax=docker/dockerfile:1.7
#
# owui-auth-bridge — Open WebUI → honeybot auth bridge. See
# docs/openwebui-google-identity.md.
#
# Build context is the REPO ROOT (so we can COPY skills/_lib/otp_auth.py and
# reuse honeybot's trust logic instead of vendoring a divergent copy):
#   build: { context: ., dockerfile: owui-auth-bridge/Dockerfile }
#
# Runs as UID 10001 — the SAME uid honeybot uses — so the shared /auth
# volume (honeybot-auth) is writable by both without a group dance.

FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY owui-auth-bridge/requirements.txt ./
RUN pip install -r requirements.txt

COPY owui-auth-bridge/bridge/ ./bridge/
# honeybot's trust logic, reused (single source of truth).
COPY skills/_lib/otp_auth.py ./_lib/otp_auth.py

# python:3.12-slim (bookworm-slim) has no `passwd` package, so append the
# user directly. UID 10001 == honeybot's, so the shared honeybot-auth
# volume mounted at /auth is writable by both containers. /auth is pre-
# created + chowned so a fresh volume inherits 10001 ownership.
RUN echo 'bridge:x:10001:10001::/app:/usr/sbin/nologin' >> /etc/passwd \
 && echo 'bridge:x:10001:' >> /etc/group \
 && mkdir -p /auth \
 && chown -R 10001:10001 /app /auth
USER bridge

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz').status==200 else 1)"

CMD ["python", "-m", "bridge"]
