#!/usr/bin/env bash
# version.sh — report the running honeybot's build provenance and compare
# to origin/main. See skills/version/SKILL.md for the why.

set -euo pipefail

JSON=0
if [[ "${1:-}" == "--json" ]]; then
  JSON=1
fi

# ---- 1. What's running -----------------------------------------------------

# Prefer the JSON file (canonical), fall back to env vars (set by Dockerfile),
# fall back to "unknown" (manual build that didn't pass --build-arg).
build_info_file="/home/honeybot/.hermes/build_info.json"
if [[ -f "$build_info_file" ]]; then
  running_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("git_sha","unknown"))' "$build_info_file" 2>/dev/null || echo unknown)"
  running_branch="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("git_branch","unknown"))' "$build_info_file" 2>/dev/null || echo unknown)"
  build_time="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("build_time","unknown"))' "$build_info_file" 2>/dev/null || echo unknown)"
else
  running_sha="${HONEYBOT_GIT_SHA:-unknown}"
  running_branch="${HONEYBOT_GIT_BRANCH:-unknown}"
  build_time="${HONEYBOT_BUILD_TIME:-unknown}"
fi

# Container start time + uptime — /proc/1's mtime is the start of PID 1.
container_started="$(stat -c '%y' /proc/1 2>/dev/null | awk '{print $1"T"$2"Z"}' | sed 's/\.[0-9]*Z$/Z/' || echo unknown)"
container_started_epoch="$(stat -c '%Y' /proc/1 2>/dev/null || echo 0)"
now_epoch="$(date -u +%s)"
if [[ "$container_started_epoch" -gt 0 ]]; then
  uptime_seconds=$(( now_epoch - container_started_epoch ))
else
  uptime_seconds=0
fi

# ---- 2. What's on origin ---------------------------------------------------

# We don't have a checkout in the container's main FS, but we can use
# git ls-remote against the public repo. Falls back gracefully if no net.
remote_sha=""
repo_slug="${HONEYBOT_REPO_SLUG:-Honeyman-Enterprises/honeybot}"
remote_branch="${HONEYBOT_DEV_BASE_BRANCH:-main}"
if command -v git >/dev/null 2>&1; then
  remote_sha="$(git ls-remote "https://github.com/${repo_slug}.git" "refs/heads/${remote_branch}" 2>/dev/null | awk '{print $1}')"
fi

# ---- 3. Compare ------------------------------------------------------------

up_to_date="null"
commits_behind="null"
if [[ -n "$remote_sha" && "$running_sha" != "unknown" ]]; then
  if [[ "$running_sha" == "$remote_sha" ]]; then
    up_to_date="true"
    commits_behind=0
  else
    up_to_date="false"
    # We don't have a local clone to count commits, so we don't actually
    # know how many commits behind we are — only that we're behind.
    commits_behind="\"unknown (running != remote)\""
  fi
fi

# ---- 4. Render -------------------------------------------------------------

if [[ "$JSON" == "1" ]]; then
  # Convert bash sentinel "null" / "true" / "false" into proper Python
  # literals before interpolating into the heredoc — Python can't parse
  # bare `null`. Strings stay quoted; booleans/None get the right type.
  py_up_to_date="None"
  case "$up_to_date" in
    true)  py_up_to_date="True" ;;
    false) py_up_to_date="False" ;;
  esac

  # commits_behind is either a bare integer (0), a quoted string
  # ("\"unknown (running != remote)\""), or "null". The first two are
  # already valid Python; "null" needs to become None.
  py_commits_behind="$commits_behind"
  [[ "$py_commits_behind" == "null" ]] && py_commits_behind="None"

  remote_block="None"
  if [[ -n "$remote_sha" ]]; then
    remote_block="{\"git_sha\": \"${remote_sha}\", \"branch\": \"${remote_branch}\"}"
  fi

  python3 - <<PY
import json
out = {
    "running": {
        "git_sha": "${running_sha}",
        "git_branch": "${running_branch}",
        "build_time": "${build_time}",
        "container_started": "${container_started}",
        "uptime_seconds": ${uptime_seconds},
    },
    "remote": ${remote_block},
    "up_to_date": ${py_up_to_date},
    "commits_behind": ${py_commits_behind},
}
print(json.dumps(out, indent=2))
PY
else
  short_running="${running_sha:0:7}"
  short_remote="${remote_sha:0:7}"
  uptime_h=$(( uptime_seconds / 3600 ))
  uptime_d=$(( uptime_h / 24 ))
  uptime_h_rem=$(( uptime_h % 24 ))
  uptime_m=$(( (uptime_seconds % 3600) / 60 ))

  # Status line. If we know one side but not the other, say so explicitly
  # instead of falling back to a vague "(remote unknown)".
  if [[ "$up_to_date" == "true" ]]; then
    status_line="✓ up to date"
  elif [[ "$up_to_date" == "false" ]]; then
    status_line="⚠ BEHIND origin/${remote_branch} (${short_remote})"
  elif [[ "$running_sha" == "unknown" && -n "$remote_sha" ]]; then
    status_line="⚠ running build has no SHA tag (Dockerfile build args weren't passed — manual rebuild?)"
  elif [[ -z "$remote_sha" ]]; then
    status_line="(could not reach origin to compare)"
  else
    status_line="(unable to compare)"
  fi

  cat <<EOF
honeybot version
  commit:    ${short_running} (origin/${remote_branch}: ${short_remote:-unknown}) ${status_line}
  branch:    ${running_branch}
  built:     ${build_time}
  container: started ${container_started} (uptime ${uptime_d}d ${uptime_h_rem}h ${uptime_m}m)
EOF
fi
