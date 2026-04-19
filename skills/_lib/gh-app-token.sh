#!/usr/bin/env bash
# gh-app-token.sh — mint a short-lived GitHub App installation access token.
#
# Why this exists:
#   The honeybot container needs to push branches and open PRs against its own
#   repo. The clean way is a GitHub App, not a long-lived PAT:
#     - Scoped to one repo (blast radius limited by install scope)
#     - Short-lived tokens (~60 min) minted on demand
#     - Revocable from the GitHub UI without rotating secrets everywhere
#     - Auditable: every API call in the audit log attributes to the App
#
# Inputs (read from 1Password via `op`):
#   op://Honeybot/GitHub Bot/app_id                 — the App's numeric ID
#   op://Honeybot/GitHub Bot/installation_id        — the install on this repo
#   op://Honeybot/GitHub Bot/github-honeybot.pem    — the App's PEM private key
#                                                     (ATTACHED FILE, not a text field)
#
# Why the PEM is an attached file, not a text field:
#   1Password's standard text/password fields are single-line and collapse
#   newlines on save, which mangles the PEM format so openssl can't parse it.
#   Attached files preserve the raw bytes. `op read` with the filename as the
#   third URL segment returns the decoded contents on stdout.
#
#   PEM_FILE (env, default "github-honeybot.pem") lets you override the
#   attached filename if you name it differently in the vault.
#
#   For backward-compat, if the attached file can't be read, falls back to
#   a text field literally named "private_key".
#
# Output:
#   Prints the installation token (ghs_...) to stdout. Nothing else goes to
#   stdout. Errors go to stderr. The token is valid for 60 minutes.
#
# Usage:
#   GH_TOKEN="$(./skills/_lib/gh-app-token.sh)"
#   export GH_TOKEN
#
# Env overrides (tests / non-prod use only):
#   HONEYBOT_GH_APP_VAULT_ITEM   default "GitHub Bot"
#   HONEYBOT_GH_APP_VAULT        default "Honeybot"
#
# Dependencies: op, openssl, curl, jq. All present in the honeybot image.

set -euo pipefail

VAULT="${HONEYBOT_GH_APP_VAULT:-Honeybot}"
ITEM="${HONEYBOT_GH_APP_VAULT_ITEM:-GitHub Bot}"

# ----- Helpers --------------------------------------------------------------

die() { echo "gh-app-token: $*" >&2; exit 1; }

# base64url: RFC 7515 / 7519 JWT encoding — URL-safe, no padding.
b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

op_read() {
  local path="$1"
  op read "$path" 2>/dev/null \
    || die "cannot read ${path} from 1Password (check OP_SERVICE_ACCOUNT_TOKEN and vault ACL)"
}

# ----- Load App credentials -------------------------------------------------

app_id="$(op_read "op://${VAULT}/${ITEM}/app_id")"
installation_id="$(op_read "op://${VAULT}/${ITEM}/installation_id")"

# PEM: attached file preferred (preserves newlines); fall back to text field
# for backward compatibility with older vault layouts.
: "${PEM_FILE:=github-honeybot.pem}"
if ! private_key="$(op read "op://${VAULT}/${ITEM}/${PEM_FILE}" 2>/dev/null)" || [[ -z "$private_key" ]]; then
    private_key="$(op_read "op://${VAULT}/${ITEM}/private_key")"
fi

[[ "$app_id" =~ ^[0-9]+$ ]] \
  || die "app_id '${app_id}' is not numeric — check the vault item"
[[ "$installation_id" =~ ^[0-9]+$ ]] \
  || die "installation_id '${installation_id}' is not numeric"
[[ "$private_key" == *"BEGIN"*"PRIVATE KEY"* ]] \
  || die "private_key does not look like a PEM block — re-paste it with line breaks preserved"

# ----- Build + sign the App JWT --------------------------------------------
# GitHub requires:
#   alg  = RS256
#   iat  = now - 60s (clock skew slack)
#   exp  = now + 10min max (we use 9 min for safety)
#   iss  = app_id
# Ref: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app

now=$(date +%s)
iat=$((now - 60))
exp=$((now + 540))

header='{"alg":"RS256","typ":"JWT"}'
payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id")"

header_b64=$(printf '%s' "$header"  | b64url)
payload_b64=$(printf '%s' "$payload" | b64url)
signing_input="${header_b64}.${payload_b64}"

# Sign with openssl. The private key is piped via stdin so it never hits disk.
signature_b64=$(
  printf '%s' "$signing_input" \
    | openssl dgst -sha256 -sign <(printf '%s' "$private_key") \
    | b64url
) || die "openssl could not sign the JWT (PEM key likely malformed)"

jwt="${signing_input}.${signature_b64}"

# ----- Exchange the JWT for an installation access token -------------------

response=$(
  curl -sS -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    --fail-with-body \
    "https://api.github.com/app/installations/${installation_id}/access_tokens"
) || {
  # Print GitHub's error body so auth problems are debuggable.
  echo "gh-app-token: GitHub rejected the JWT:" >&2
  echo "${response:-<no response body>}" >&2
  exit 2
}

token=$(printf '%s' "$response" | jq -r '.token // empty')
[[ -n "$token" ]] || die "GitHub response did not include a token field — got: $response"

# Stdout: the token, and only the token.
printf '%s\n' "$token"
