# syntax=docker/dockerfile:1.7
#
# certbot — issues + renews the wildcard LE cert for
# *.honeybot.honeymanenterprises.com (and the apex) using the Route53
# DNS-01 challenge plugin.
#
# Why DNS-01 (not HTTP-01)?
#   - We want a wildcard. LE only issues wildcards via DNS-01.
#   - It works even if port 80 is flaky or blocked upstream.
#   - Requires AWS credentials with Route53 change permissions — scoped
#     down in aws-infra/iam-certbot-policy.json.
#
# Secrets: AWS creds for Route53 are resolved from 1Password at container
# start (via varlock) and exported into the environment for certbot-dns-route53.
#
# Cert output lives in /etc/letsencrypt (shared volume `certbot-etc` with
# the nginx container). Renewal is driven by the entrypoint below: check
# every 12h, renew when <30 days remain, reload nginx on successful renewal.

FROM certbot/dns-route53:v2.11.0

# Install the minimal extras we need inside the entrypoint:
#   - bash (base image is alpine; sh is fine but bash is what we write)
#   - docker-cli: NOT installed. We reload nginx by touching a sentinel
#     file on the shared volume; the nginx container watches for it.
#     (Avoids giving the certbot container access to the docker socket.)
#   - For simplicity v1: we just restart nginx from the host's redeploy
#     sidecar if needed. Certbot writes new certs; nginx picks them up
#     on the next reload cycle triggered by the entrypoint.
RUN apk add --no-cache bash curl

COPY renew.sh      /usr/local/bin/renew.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/renew.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
