#!/usr/bin/env bash
# gmail.sh — per-user Gmail operations. The Slack user is inferred from
# $HONEYBOT_SLACK_USER (or --user UID as the FIRST arg). The user's
# refresh token is read from 1Password, exchanged for an access token,
# and used to call the Gmail API. The access token never touches disk.
#
# Subcommands:
#   search "<query>" [--max N]
#   get <message_id>
#   send --to <addr> --subject <s> --body <b> [--from <addr>] [--html]
#   reply <message_id> --body <b> [--from <addr>]
#
# Output: JSON on stdout (same shape as bundled google-workspace skill).

set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pull off --user if it's first
user_arg=()
if [[ "${1:-}" == "--user" ]]; then
  user_arg=(--user "$2")
  shift 2
elif [[ "${1:-}" == --user=* ]]; then
  user_arg=("$1")
  shift
fi

# Mint access token (this is the only place that touches the refresh token)
ACCESS_TOKEN="$("$BIN_DIR/_token.sh" "${user_arg[@]}")"
export ACCESS_TOKEN

cleanup() { unset ACCESS_TOKEN; }
trap cleanup EXIT

API="https://gmail.googleapis.com/gmail/v1/users/me"

usage() {
  cat >&2 <<'USAGE'
usage:
  gmail.sh [--user UID] search "<query>" [--max N]
  gmail.sh [--user UID] get <message_id>
  gmail.sh [--user UID] send --to <addr> --subject <s> --body <b> [--from <addr>] [--html]
  gmail.sh [--user UID] reply <message_id> --body <b> [--from <addr>]
USAGE
  exit 2
}

[[ $# -lt 1 ]] && usage
sub="$1"; shift

py_b64url_encode() {
  # Read stdin, output URL-safe base64 (Gmail's required encoding for raw)
  python3 -c '
import sys, base64
data = sys.stdin.buffer.read()
print(base64.urlsafe_b64encode(data).decode().rstrip("="))
'
}

py_b64_decode() {
  python3 -c '
import sys, base64
data = sys.stdin.buffer.read().strip()
# Gmail returns urlsafe-b64 without padding
data += b"=" * (-len(data) % 4)
sys.stdout.buffer.write(base64.urlsafe_b64decode(data))
'
}

case "$sub" in
  search)
    [[ $# -lt 1 ]] && usage
    q="$1"; shift
    max=20
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --max) max="$2"; shift 2 ;;
        *) echo "gmail.sh: unknown arg: $1" >&2; usage ;;
      esac
    done
    encoded_q="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$q")"
    list="$(curl -sS --fail-with-body \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "${API}/messages?q=${encoded_q}&maxResults=${max}")"

    # For each message id, fetch metadata in parallel and assemble JSON
    python3 - "$list" <<'PY'
import json, os, sys, subprocess, concurrent.futures
list_resp = json.loads(sys.argv[1])
msgs = list_resp.get("messages", [])
if not msgs:
    print("[]")
    sys.exit(0)

token = os.environ["ACCESS_TOKEN"]
api = "https://gmail.googleapis.com/gmail/v1/users/me"

def fetch(mid):
    import urllib.request
    url = f"{api}/messages/{mid}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Date"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
    results = list(ex.map(fetch, [m["id"] for m in msgs]))

out = []
for m in results:
    headers = {h["name"].lower(): h["value"] for h in m.get("payload", {}).get("headers", [])}
    out.append({
        "id": m.get("id"),
        "threadId": m.get("threadId"),
        "from": headers.get("from", ""),
        "to": headers.get("to", ""),
        "subject": headers.get("subject", ""),
        "date": headers.get("date", ""),
        "snippet": m.get("snippet", ""),
        "labels": m.get("labelIds", []),
    })
print(json.dumps(out, indent=2))
PY
    ;;

  get)
    [[ $# -lt 1 ]] && usage
    mid="$1"; shift
    raw="$(curl -sS --fail-with-body \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "${API}/messages/${mid}?format=full")"
    python3 - "$raw" <<'PY'
import json, sys, base64
m = json.loads(sys.argv[1])
headers = {h["name"].lower(): h["value"] for h in m.get("payload", {}).get("headers", [])}

def walk(part):
    """Return first text/plain body found, falling back to text/html."""
    mt = part.get("mimeType", "")
    body = part.get("body", {})
    data = body.get("data")
    if mt == "text/plain" and data:
        return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4)).decode("utf-8", "replace")
    for sub in part.get("parts", []) or []:
        r = walk(sub)
        if r:
            return r
    if mt == "text/html" and data:
        return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4)).decode("utf-8", "replace")
    return ""

body_text = walk(m.get("payload", {}))

print(json.dumps({
    "id": m.get("id"),
    "threadId": m.get("threadId"),
    "from": headers.get("from", ""),
    "to": headers.get("to", ""),
    "subject": headers.get("subject", ""),
    "date": headers.get("date", ""),
    "labels": m.get("labelIds", []),
    "body": body_text,
}, indent=2))
PY
    ;;

  send|reply)
    to=""
    subject=""
    body=""
    from_addr=""
    is_html=0
    reply_to_id=""

    if [[ "$sub" == "reply" ]]; then
      [[ $# -lt 1 ]] && usage
      reply_to_id="$1"; shift
    fi

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --to) to="$2"; shift 2 ;;
        --subject) subject="$2"; shift 2 ;;
        --body) body="$2"; shift 2 ;;
        --from) from_addr="$2"; shift 2 ;;
        --html) is_html=1; shift ;;
        *) echo "gmail.sh: unknown arg: $1" >&2; usage ;;
      esac
    done

    # For replies, look up subject + threadId + Message-ID from original
    thread_id=""
    in_reply_to=""
    if [[ -n "$reply_to_id" ]]; then
      orig="$(curl -sS --fail-with-body \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        "${API}/messages/${reply_to_id}?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Message-Id")"
      thread_id="$(printf '%s' "$orig" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("threadId",""))')"
      orig_subject="$(printf '%s' "$orig" | python3 -c '
import json, sys
m = json.load(sys.stdin)
hs = {h["name"].lower(): h["value"] for h in m.get("payload",{}).get("headers",[])}
print(hs.get("subject",""))
')"
      orig_msgid="$(printf '%s' "$orig" | python3 -c '
import json, sys
m = json.load(sys.stdin)
hs = {h["name"].lower(): h["value"] for h in m.get("payload",{}).get("headers",[])}
print(hs.get("message-id",""))
')"
      orig_from="$(printf '%s' "$orig" | python3 -c '
import json, sys
m = json.load(sys.stdin)
hs = {h["name"].lower(): h["value"] for h in m.get("payload",{}).get("headers",[])}
print(hs.get("from",""))
')"
      if [[ -z "$to" ]]; then to="$orig_from"; fi
      if [[ -z "$subject" ]]; then
        if [[ "$orig_subject" == Re:* ]]; then
          subject="$orig_subject"
        else
          subject="Re: $orig_subject"
        fi
      fi
      in_reply_to="$orig_msgid"
    fi

    [[ -z "$to" || -z "$body" ]] && {
      echo "gmail.sh: --to and --body are required" >&2
      usage
    }
    [[ -z "$subject" ]] && subject="(no subject)"

    # Build RFC 822 message
    raw_b64="$(python3 - <<PY | tr -d '\n'
import base64, sys
to = ${to@Q}
subject = ${subject@Q}
body = ${body@Q}
from_addr = ${from_addr@Q}
is_html = ${is_html}
in_reply_to = ${in_reply_to@Q}

ctype = "text/html; charset=UTF-8" if is_html else "text/plain; charset=UTF-8"
lines = []
lines.append(f"To: {to}")
if from_addr:
    lines.append(f"From: {from_addr}")
lines.append(f"Subject: {subject}")
lines.append(f"Content-Type: {ctype}")
lines.append("MIME-Version: 1.0")
if in_reply_to:
    lines.append(f"In-Reply-To: {in_reply_to}")
    lines.append(f"References: {in_reply_to}")
lines.append("")
lines.append(body)
msg = "\r\n".join(lines).encode("utf-8")
sys.stdout.write(base64.urlsafe_b64encode(msg).decode().rstrip("="))
PY
)"

    payload="$(python3 -c '
import json, sys
raw, tid = sys.argv[1], sys.argv[2]
d = {"raw": raw}
if tid:
    d["threadId"] = tid
print(json.dumps(d))
' "$raw_b64" "$thread_id")"

    response="$(curl -sS --fail-with-body -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      "${API}/messages/send" \
      -d "$payload")"

    python3 -c '
import json, sys
m = json.loads(sys.argv[1])
print(json.dumps({"status":"sent","id":m.get("id"),"threadId":m.get("threadId")}, indent=2))
' "$response"
    ;;

  *)
    echo "gmail.sh: unknown subcommand: $sub" >&2
    usage
    ;;
esac
