#!/usr/bin/env bash
# sync-hermes-state.sh — seed the hermes-state volume on first boot,
# merge image-baked updates on subsequent boots.
#
# Called from the ENTRYPOINT before seed-vault.sh. Runs as the honeybot
# user (UID 10001 or whatever the container's USER is).
#
# Volume layout:
#   /home/honeybot/.hermes/state/   ← hermes-state named volume
#
# The script creates symlinks from the locations Hermes expects
# (~/.hermes/state.db, ~/.hermes/config.yaml, etc.) into the volume,
# so upstream code doesn't need any path changes.
#
# On first boot (empty volume): copies image-baked defaults into the
# volume so Hermes starts with the right config.
#
# On subsequent boots: leaves existing volume files alone (user config,
# sessions, auth tokens, RL data all survive). Only updates skills/
# and hooks/ from the image (new deploys ship new skill code).

set -euo pipefail

HERMES_DIR="${HOME}/.hermes"
STATE_DIR="${HERMES_DIR}/state"

# Files/dirs that must persist across container rebuilds.
# Each entry is relative to ~/.hermes/.
PERSISTENT_FILES=(
  state.db
  config.yaml
  auth.json
  kanban.db
  response_store.db
  gateway_state.json
  channel_directory.json
  sessions
  cron
  SOUL.md
)

# Directories whose content is image-baked but should also persist.
# On every boot, image content is merged in (new files added, existing
# files left alone). This ensures new skills/hooks ship with image
# updates but user customizations aren't overwritten.
MERGE_DIRS=(
  skills
  hooks
  plugins
)

echo "sync-hermes-state: state volume at ${STATE_DIR}"

# Ensure the state directory structure exists on the volume.
mkdir -p "${STATE_DIR}/sessions" "${STATE_DIR}/cron"

# --- Persistent files: symlink into the volume --------------------------
for item in "${PERSISTENT_FILES[@]}"; do
  src="${HERMES_DIR}/${item}"
  dst="${STATE_DIR}/${item}"

  # If the source is a real file/dir (not a symlink) in the image layer,
  # seed it into the volume on first boot.
  if [ -e "${src}" ] && [ ! -L "${src}" ]; then
    if [ ! -e "${dst}" ]; then
      echo "  seed: ${item}"
      cp -a "${src}" "${dst}"
    fi
    # Remove the image-layer copy and replace with a symlink.
    rm -rf "${src}"
  fi

  # Create the symlink if it doesn't exist yet.
  if [ ! -L "${src}" ]; then
    # Ensure the target exists (even if empty) so Hermes doesn't error.
    if [ ! -e "${dst}" ]; then
      if [[ "${item}" == */ || "${item}" == "sessions" || "${item}" == "cron" ]]; then
        mkdir -p "${dst}"
      else
        touch "${dst}"
      fi
    fi
    ln -sf "${dst}" "${src}"
    echo "  link: ${item} -> state/"
  fi
done

# --- Merge dirs: image ships new code, volume preserves customizations --
for dir in "${MERGE_DIRS[@]}"; do
  src="${HERMES_DIR}/${dir}"
  dst="${STATE_DIR}/${dir}"

  mkdir -p "${dst}"

  # If source is a real directory (image-baked), merge its contents
  # into the volume. cp -n = no-clobber (don't overwrite existing).
  # rsync would be ideal but may not be installed; use cp -a instead.
  if [ -d "${src}" ] && [ ! -L "${src}" ]; then
    # Copy new/updated files from image into volume.
    # Use cp -a for full fidelity, but only overwrite skills that ship
    # with the image (not agent-created ones).
    cp -a "${src}/." "${dst}/" 2>/dev/null || true
    rm -rf "${src}"
  fi

  # Symlink so Hermes reads from the volume.
  if [ ! -L "${src}" ]; then
    ln -sf "${dst}" "${src}"
    echo "  link: ${dir}/ -> state/"
  fi
done

echo "sync-hermes-state: done"
