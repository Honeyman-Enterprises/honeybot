#!/usr/bin/env bash
# Deploy hook invoked by certbot after a successful renewal.
#
# Writes a sentinel file on the shared certbot-etc volume so the nginx
# container's reload watcher can pick up the new cert. (Implemented as a
# simple inotify-style loop in the nginx entrypoint would be ideal; v1
# relies on `docker kill -s HUP nginx` issued from the host redeploy
# sidecar if cert files change. Sentinel here is for observability.)
set -euo pipefail

ts="$(date -Iseconds)"
echo "${ts} renewed ${RENEWED_DOMAINS:-unknown} -> ${RENEWED_LINEAGE:-unknown}" \
  >> /etc/letsencrypt/renew.log
touch /etc/letsencrypt/.renewed
echo "certbot renew.sh: sentinel touched at ${ts}"
