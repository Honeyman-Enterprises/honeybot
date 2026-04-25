#!/bin/sh
# secrets-init-entrypoint.sh — bring up the one-shot secrets-init container.
#
# Container model: this script starts as ROOT, prepares an op-CLI-
# compatible home directory for the configured runtime UID, registers
# that UID in /etc/passwd so getpwuid(2) returns a sane home, then
# drops privileges via gosu and chains the bring-up scripts.
#
# Why this pattern (and not compose's `user:` directive):
#
#   The 1Password CLI has TWO separate, incompatible safety checks
#   that both break under a `user:` override on a stock image:
#
#   1. CLI-side. `op` requires $HOME (and its config subtree) to be
#      OWNED by the current UID, with op-friendly ancestor permissions.
#      /tmp doesn't qualify even with the sticky bit (root:root). A
#      mktemp dir under /tmp creates a UID-owned leaf, but op walks
#      ancestors and rejects with:
#        Can't safely access "/tmp/.../.config/op" because it's not
#        owned by the current user.
#
#   2. Daemon-side. `op-daemon` resolves its PID-file path via
#      getpwuid(getuid()).pw_dir, NOT $HOME. If the runtime UID has no
#      /etc/passwd entry, getpwuid returns NULL and the daemon falls
#      back to a stale "/home/<x>/op-daemon.pid" path that doesn't
#      exist in the container, failing with:
#        couldn't start daemon: open /home/<x>/op-daemon.pid:
#        no such file or directory
#
#   Compose's `user:` directive can't fix either: by the time the
#   entrypoint runs you're already the unprivileged UID, with no chown
#   rights and no way to edit /etc/passwd. So we start as root, do
#   both fixups, and drop privileges via gosu — the canonical pattern
#   used by the official Postgres / MySQL / Redis images.
#
# Idempotent: re-runs cleanly. /etc/passwd is rewritten in-place; the
# home dir is recreated each run (it holds only ephemeral op state).

set -eu

UID_TARGET="${HONEYBOT_HOST_UID:-1000}"
GID_TARGET="${HONEYBOT_HOST_GID:-1000}"
RUNTIME_USER=secrets-init
RUNTIME_HOME=/home/secrets-init

# Sanity: must start as root. Catches an accidental `user:` reintroduction
# in compose with a clear message instead of a confusing chown EPERM.
if [ "$(id -u)" -ne 0 ]; then
  echo "secrets-init-entrypoint: must start as root (got UID $(id -u))." >&2
  echo "Remove any 'user:' override from the secrets-init compose service" >&2
  echo "(other than 'user: \"0:0\"'). Privilege drop happens in this script." >&2
  exit 1
fi

# Ensure /etc/group has GID_TARGET. Wipe any pre-existing entry on that
# GID first to keep getgrgid(2) consistent with the name we register.
sed -i "/^[^:]*:x:${GID_TARGET}:/d" /etc/group
echo "${RUNTIME_USER}:x:${GID_TARGET}:" >> /etc/group

# Ditto /etc/passwd for UID_TARGET. The home field MUST point at
# RUNTIME_HOME so op-daemon's getpwuid lookup matches what we chown
# below and what we export as $HOME for the CLI.
sed -i "/^[^:]*:x:${UID_TARGET}:/d" /etc/passwd
echo "${RUNTIME_USER}:x:${UID_TARGET}:${GID_TARGET}:Honeybot secrets-init runtime:${RUNTIME_HOME}:/bin/sh" \
  >> /etc/passwd

# Fresh home dir owned by the target UID. Mode 0700 — op's CLI-side
# check rejects world/group readable config dirs.
rm -rf "${RUNTIME_HOME}"
install -d -m 0700 -o "${UID_TARGET}" -g "${GID_TARGET}" "${RUNTIME_HOME}"

# Export the env the dropped child inherits. gosu preserves env by
# default, so `export` here is sufficient — no need to re-set inside
# the inner shell.
export HOME="${RUNTIME_HOME}"
export USER="${RUNTIME_USER}"
export LOGNAME="${RUNTIME_USER}"
export XDG_RUNTIME_DIR="${RUNTIME_HOME}"

# cd before exec so the dropped child starts in the script directory.
# /home/honeybot is mode 0755 (see Dockerfile) so the dropped UID can
# traverse it.
cd /home/honeybot

# exec replaces this shell so the container's exit status equals the
# chain's exit status — which is what compose's
# depends_on: condition: service_completed_successfully gates on.
exec gosu "${UID_TARGET}:${GID_TARGET}" /bin/sh -euc '
  ./seed-vault.sh
  ./emit-runtime-env.sh /repo/.env.runtime
  ./ensure-aws-infra.sh
'
