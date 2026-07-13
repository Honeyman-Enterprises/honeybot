#!/usr/bin/env bash
# seed-credential-pool.sh — populate Hermes' auth.json credential pool
# from environment variables on every boot.
#
# Called from the ENTRYPOINT after sync-hermes-state.sh (so auth.json is
# already symlinked into the hermes-state volume) and AFTER varlock has
# resolved secrets into the environment.
#
# This is NOT a replacement for `hermes auth add` — it covers the case
# where API keys arrive via environment variables (varlock / 1Password)
# rather than interactive CLI entry. The credential pool is what lets
# Hermes switch providers at runtime without re-exporting env vars.
#
# Idempotent: existing pool entries are left alone. Only adds providers
# whose env var is set and non-empty AND aren't already in the pool.

set -euo pipefail

AUTH_JSON="${HOME}/.hermes/auth.json"

# Ensure auth.json exists with the minimum structure.
if [ ! -f "$AUTH_JSON" ]; then
  echo '{"version": 1, "providers": {}, "credential_pool": {}}' > "$AUTH_JSON"
  chmod 600 "$AUTH_JSON"
fi

# Map of provider name → env var containing the API key.
# Add new providers here as needed.
declare -A PROVIDERS=(
  [anthropic]="ANTHROPIC_API_KEY"
  [openai]="OPENAI_API_KEY"
)

python3 << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone

auth_path = os.path.expanduser("~/.hermes/auth.json")

try:
    with open(auth_path) as f:
        auth = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    auth = {"version": 1, "providers": {}, "credential_pool": {}}

if "credential_pool" not in auth:
    auth["credential_pool"] = {}

pool = auth["credential_pool"]
now = datetime.now(timezone.utc).isoformat()

# Provider → env var mapping
providers = {
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
}

changed = False
for provider, env_var in providers.items():
    key = os.environ.get(env_var, "").strip()
    if not key:
        continue

    # Check if this provider already has a credential in the pool.
    existing = pool.get(provider, [])
    if existing:
        # Already seeded — don't touch it (user may have rotated keys
        # via `hermes auth add`).
        continue

    pool[provider] = [{
        "api_key": key,
        "label": f"{provider}-env-seed",
        "added_at": now,
    }]
    changed = True
    print(f"seed-credential-pool: added {provider} from ${env_var}")

if changed:
    with open(auth_path, "w") as f:
        json.dump(auth, f, indent=2)
    print("seed-credential-pool: auth.json updated")
else:
    print("seed-credential-pool: credential pool up to date")
PYEOF
