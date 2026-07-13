#!/usr/bin/env bash
# seed-credential-pool.sh — ensure Hermes' ~/.hermes/.env has API keys
# from the varlock-resolved environment, so Hermes' built-in credential
# pool auto-seeder (agent/credential_pool.py::_seed_from_env) can find
# them in ~/.hermes/.env even after the process env changes.
#
# Called from the CMD (inside varlock's child process) on every boot,
# AFTER varlock has resolved op(...) references into the environment.
#
# Why this exists:
#   Hermes' credential pool reads ~/.hermes/.env first (via load_env()),
#   then falls back to os.environ. The varlock env is available in the
#   current process, but Hermes' .env file lives on the hermes-state
#   volume and survives container rebuilds. Writing keys there ensures
#   they're always discoverable regardless of how the process started.
#
# Idempotent: existing .env entries are not overwritten.

set -euo pipefail

HERMES_ENV="${HOME}/.hermes/.env"

# Ensure the file exists
touch "$HERMES_ENV"
chmod 600 "$HERMES_ENV"

# Provider env vars to seed into .env
VARS=(
  ANTHROPIC_API_KEY
  OPENAI_API_KEY
)

changed=false
for var in "${VARS[@]}"; do
  val="${!var:-}"
  if [ -z "$val" ]; then
    continue
  fi

  # Don't overwrite existing entries
  if grep -q "^${var}=" "$HERMES_ENV" 2>/dev/null; then
    continue
  fi

  echo "${var}=${val}" >> "$HERMES_ENV"
  echo "seed-credential-pool: added ${var} to ~/.hermes/.env"
  changed=true
done

if [ "$changed" = false ]; then
  echo "seed-credential-pool: .env up to date"
fi
