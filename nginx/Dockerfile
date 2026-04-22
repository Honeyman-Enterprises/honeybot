# syntax=docker/dockerfile:1.7
#
# nginx — TLS termination + reverse proxy for Honeybot public webhook traffic.
#
# Why not plain nginx:alpine? We bake in the conf files at build time so the
# image is self-contained and reproducible from the repo — no runtime volume
# mounts for config, no drift between dev/prod. Certs live on a named volume
# (`certbot-etc`) shared with the certbot service; that's the only stateful
# piece.
#
# Listens on:
#   80/tcp  → ACME HTTP-01 challenge fallback + redirect to 443
#   443/tcp → TLS-terminated reverse proxy
#
# Upstream services are reached over the `honeynet` docker network by
# service name (e.g. `honeybot:8080`, `mcp-mercury:8000`).

FROM nginx:1.27-alpine

# Drop the default server block; we supply our own via conf.d.
RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx.conf        /etc/nginx/nginx.conf
COPY conf.d/           /etc/nginx/conf.d/

# Health check: nginx must be serving on 80 (HTTP-01 ACME path).
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1/healthz || exit 1

EXPOSE 80 443
