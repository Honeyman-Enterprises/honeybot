# syntax=docker/dockerfile:1.7
#
# nginx — OpenResty (nginx + LuaJIT + lua-nginx-module) with in-process
# Let's Encrypt issuance + renewal via lua-resty-acme.
#
# Why OpenResty + lua-resty-acme instead of vanilla nginx + certbot,
# or nginx pulling AWS ACM cert material at start?
#
#   - Public ACM certs cannot be exported from AWS (private key never
#     leaves ACM). Private CA certs can, but cost ~$400/mo per CA.
#   - EIP routes directly to this EC2 — there's no ALB/CloudFront in
#     front doing TLS termination with an ACM handle.
#   - certbot requires a separate binary + crontab / sidecar for
#     renewal. We've explicitly ruled out host crons.
#   - lua-resty-acme runs entirely inside the nginx worker: first
#     handshake for a whitelisted domain triggers HTTP-01 issuance,
#     renewal is a background timer. Zero host-side tooling.
#
# TLS certs + ACME account state persist on the `acme-storage` named
# volume (mounted at /etc/openresty/acme-storage). A fresh volume
# triggers re-issuance on first HTTPS request per domain; cached
# certs survive container restarts.
#
# HTTP-01 challenge requires port 80 reachable from the public
# internet. The EIP + a manually-managed Route53 apex A record handle
# that.
#
# Bootstrap cert: a self-signed pair is baked into the image so the
# `ssl_certificate` / `ssl_certificate_key` directives have files to
# open at nginx config load. It is never served to real clients for
# whitelisted domains — ssl_certificate_by_lua_block replaces it
# mid-handshake. It's only there so nginx can pass `-t` and start up.
#
# Listens on:
#   80/tcp  → ACME challenge + /healthz + redirect to 443
#   443/tcp → TLS-terminated reverse proxy
#
# Do NOT reintroduce certbot volumes, /etc/letsencrypt/* paths, AWS
# ACM cert-export logic, or Route53 DNS-01 flows here.

FROM openresty/openresty:1.25.3.2-2-alpine-fat

# --- lua-resty-acme + transitive deps ---------------------------------
# `-fat` variant includes luarocks + the native toolchain needed to
# build lua-resty-openssl. Install git for luarocks fetch, then drop it
# after install to keep the image slim.
#
# Why every rock is pinned (and why bare `luarocks install lua-resty-acme`
# is broken right now):
#
# As of 2025, the LuaRocks public manifests at luarocks.org and the
# GitHub mirror have grown past Lua 5.1's hard-coded 65536-constants
# limit per chunk (`MAXARG_Bx`). LuaJIT (which OpenResty embeds) speaks
# the 5.1 dialect, so loading the manifest fails with:
#
#   Failed loading manifest for https://luarocks.org:
#     ...main function has more than 65536 constants
#   Error: No results matching query were found for Lua 5.1.
#
# When you give `luarocks install` an explicit name AND version, it
# fetches that one rockspec directly from the rocks server and skips the
# manifest parse entirely. So we pin everything: leaf deps first
# (no transitive resolution needed), then the top-level rock.
#
# To bump versions:
#   - lua-resty-http:    https://github.com/ledgetech/lua-resty-http/tags
#   - lua-resty-openssl: https://github.com/fffonion/lua-resty-openssl/tags
#   - lua-resty-acme:    https://github.com/fffonion/lua-resty-acme/tags
RUN apk add --no-cache git openssl \
 && luarocks install lua-resty-http    0.17.2 \
 && luarocks install lua-resty-openssl 1.7.1 \
 && luarocks install lua-resty-acme    0.16.0 \
 && apk del git

# --- Bootstrap self-signed cert ---------------------------------------
# Fallback pair referenced by the ssl_certificate / ssl_certificate_key
# directives so nginx can start before any real cert has been issued.
# Issued to `bootstrap.invalid` so it's visually obvious in browser
# error pages if it ever does get served (it shouldn't, because SNI
# for whitelisted hosts goes through ssl_certificate_by_lua_block).
RUN mkdir -p /etc/nginx/ssl \
 && openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -subj "/CN=bootstrap.invalid" \
      -keyout /etc/nginx/ssl/bootstrap.key \
      -out    /etc/nginx/ssl/bootstrap.crt \
 && chmod 600 /etc/nginx/ssl/bootstrap.key

# --- ACME storage dir -------------------------------------------------
# The compose `acme-storage` named volume mounts here. Ownership is
# set so the OpenResty workers (run as `nobody`) can write issued
# certs + account keys. Mode 700 — nothing in here should be world-
# readable.
RUN mkdir -p /etc/openresty/acme-storage \
 && chown nobody:nobody /etc/openresty/acme-storage \
 && chmod 700 /etc/openresty/acme-storage

# Drop the upstream default server block; we supply our own via conf.d.
RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx.conf        /etc/nginx/nginx.conf
COPY conf.d/           /etc/nginx/conf.d/

# Health check: /healthz on port 80, always unconditionally 200.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1/healthz || exit 1

EXPOSE 80 443
