# Honeybot redeploy sidecar.
#
# Tiny image whose only job is:
#   loop { git fetch origin main; if new commits: docker compose up -d --build }
#
# Runs alongside the `honeybot` service in docker-compose.yml. Bind-mounts the
# host's docker socket so it can issue `docker compose` against the host
# daemon, and bind-mounts the repo so `git fetch` on the host is reflected
# here. No GitHub App auth needed — the repo is public, anonymous HTTPS fetch
# works. If the repo ever goes private, wire `skills/_lib/gh-app-token.sh`
# into watch.sh and set `git config credential.helper` accordingly.

FROM docker:27-cli-alpine3.20

# git + bash for watch.sh; curl to pull the compose plugin
RUN apk add --no-cache bash git curl ca-certificates

# Compose plugin — docker:cli ships the daemon client but not compose v2.
# Pin the same version bootstrap/ec2-userdata.sh uses so behavior matches
# the host if someone ever shells in to debug.
ARG COMPOSE_VER=v2.29.7
RUN mkdir -p /usr/local/lib/docker/cli-plugins \
 && arch="$(uname -m)" \
 && case "$arch" in \
      x86_64)  compose_arch=x86_64 ;; \
      aarch64) compose_arch=aarch64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac \
 && curl -sSfL "https://github.com/docker/compose/releases/download/${COMPOSE_VER}/docker-compose-linux-${compose_arch}" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose \
 && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose \
 && docker compose version

WORKDIR /repo

COPY watch.sh /usr/local/bin/watch.sh
RUN chmod +x /usr/local/bin/watch.sh

ENTRYPOINT ["/usr/local/bin/watch.sh"]
