#!/usr/bin/env bash
# =============================================================================
# scripts/install/preflight-sdk-versions.sh    [D2]
#
# Defect D2: image baked SDK 0.3.0 but identity dist needed 0.5.x. Hot-patched
# the SDK on the running container — fragile and lost on any restart.
#
# This preflight inspects every service node_modules/@zorbit-platform/sdk-node
# inside the env containers and FAILS if any installed SDK version is below
# the per-service minimum from
# zorbit-core/platform-spec/sdk-min-versions.json.
#
# Inputs:
#   ENV_PREFIX               REQUIRED  e.g. zq, ze
#   MIN_SPEC_FILE            default platform-spec/sdk-min-versions.json
#   SSH_TARGET               default '' (run locally if empty)
#
# Exit codes:
#   0 ok
#   1 at least one service below minimum
# =============================================================================
set -euo pipefail

ENV_PREFIX="${ENV_PREFIX:-${1:-}}"
MIN_SPEC_FILE="${MIN_SPEC_FILE:-/work/zorbit/02_repos/zorbit-core/platform-spec/sdk-min-versions.json}"
SSH_TARGET="${SSH_TARGET:-}"
REPORT_DIR="${ZORBIT_INSTALL_LOG_DIR:-/var/log/zorbit-install}"
mkdir -p "$REPORT_DIR" 2>/dev/null || REPORT_DIR=/tmp

[[ -z "$ENV_PREFIX" ]] && { echo "ERR: ENV_PREFIX (or first arg) required"; exit 1; }
[[ ! -f "$MIN_SPEC_FILE" ]] && {
  # try alternate paths
  for cand in \
    /Users/s/workspace/zorbit/02_repos/zorbit-core/platform-spec/sdk-min-versions.json \
    "$(dirname "$0")/../../../../zorbit-core/platform-spec/sdk-min-versions.json" \
    "$(dirname "$0")/../../platform-spec/sdk-min-versions.json"; do
    [[ -f "$cand" ]] && MIN_SPEC_FILE="$cand" && break
  done
}
[[ ! -f "$MIN_SPEC_FILE" ]] && { echo "ERR: cannot locate sdk-min-versions.json"; exit 1; }

DEFAULT_MIN=$(jq -r '.services._default' "$MIN_SPEC_FILE")

run() { if [[ -n "$SSH_TARGET" ]]; then ssh "$SSH_TARGET" "$@"; else bash -c "$@"; fi; }

# Helper: semver gte (returns 0 if a >= b)
semver_gte() {
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 0
  local hi
  hi=$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)
  [[ "$hi" == "$a" ]]
}

fail=0
declare -a report

for c in ${ENV_PREFIX}-core ${ENV_PREFIX}-pfs ${ENV_PREFIX}-apps ${ENV_PREFIX}-ai; do
  echo "==> inspecting container $c"
  # find every service dir under /app and read its sdk-node version
  while IFS=$'\t' read -r svc ver; do
    [[ -z "$svc" ]] && continue
    min_for_svc=$(jq -r --arg s "$svc" '.services[$s] // .services._default' "$MIN_SPEC_FILE")
    if semver_gte "$ver" "$min_for_svc"; then
      echo "  ok  ${svc}: ${ver} >= ${min_for_svc}"
      report+=("{\"container\":\"$c\",\"service\":\"$svc\",\"installed\":\"$ver\",\"min\":\"$min_for_svc\",\"status\":\"ok\"}")
    else
      echo "  FAIL ${svc}: ${ver} < ${min_for_svc}"
      fail=1
      report+=("{\"container\":\"$c\",\"service\":\"$svc\",\"installed\":\"$ver\",\"min\":\"$min_for_svc\",\"status\":\"fail\"}")
    fi
  done < <(run "docker exec $c sh -c 'for d in /app/*/node_modules/@zorbit-platform/sdk-node/package.json; do svc=\$(echo \$d | sed -E \"s|/app/||;s|/node_modules.*||\"); ver=\$(grep -oE \"\\\"version\\\":[[:space:]]*\\\"[^\\\"]+\\\"\" \$d | head -1 | sed -E \"s/.*: *\\\"([^\\\"]+)\\\".*/\\1/\"); echo \"\$svc\\t\$ver\"; done' 2>/dev/null")
done

# Write JSON report
{
  printf '{"phase":"preflight-sdk-versions","env":"%s","default_min":"%s","results":[' \
    "$ENV_PREFIX" "$DEFAULT_MIN"
  IFS=,; printf '%s' "${report[*]}"; unset IFS
  printf '],"result":"%s"}\n' "$([[ $fail -eq 0 ]] && echo pass || echo fail)"
} > "${REPORT_DIR}/preflight-sdk-versions.json" || true

if (( fail )); then
  echo
  echo "==> D2 preflight FAILED — at least one service has SDK below minimum."
  echo "    Rebuild the bundle from main HEAD with the current SDK pinned."
  exit 1
fi

echo "==> D2 preflight PASS"
exit 0
