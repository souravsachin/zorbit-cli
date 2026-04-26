#!/usr/bin/env bash
# =============================================================================
# check-source-dist-drift.sh — pre-deploy guard against stale dist/
# =============================================================================
# Item 38 (soldier (u), MSG-079, 2026-04-26).
#
# Lesson from cycle-105 (orchestrator 17:33 +07): we found 30 services with
# stale dist/ (dated Apr 19-20) that did NOT reflect just-merged source. The
# CI/CD pipeline merged a fix to source, redeployed the bundle, but the
# bundle's dist/ was the pre-merge build — so the deployed code was from
# before the fix. "Merged != deployed" silently.
#
# This guard catches that. For each service repo it compares the most
# recent mtime under src/ against the most recent mtime under dist/.
# If any source file is newer than the newest dist artifact, drift is
# detected and the operator is warned.
#
# Approach: mtime-based (zero-touch on package.json) — simpler than hash
# emission and good enough to catch the "forgot to rebuild" failure mode
# documented above. A future iteration can switch to SHA-256 of src/**/*.ts
# vs a stored dist/.source-hash for hermetic comparison.
#
# Mode: WARN by default (does not fail the build). Pass --fail-on-drift to
# turn warnings into hard failures (intended for CI after a stabilisation
# period). Per MSG-079 directive: "initially as warn, flip to fail later".
#
# Usage:
#   bash check-source-dist-drift.sh [--repo-root <dir>] [--fail-on-drift]
#                                   [--repo <name>]   [--quiet]
#
# Defaults:
#   --repo-root  /Users/s/workspace/zorbit/02_repos
#   --repo       (all zorbit-{cor,pfs,app,ai}-* under repo-root)
#
# Exit codes:
#   0  no drift OR drift detected in --warn mode (default)
#   1  drift detected AND --fail-on-drift was set
#   2  bad invocation
# =============================================================================
set -uo pipefail

REPO_ROOT="/Users/s/workspace/zorbit/02_repos"
FAIL_ON_DRIFT=false
SINGLE_REPO=""
QUIET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)     REPO_ROOT="$2"; shift 2 ;;
    --repo)          SINGLE_REPO="$2"; shift 2 ;;
    --fail-on-drift) FAIL_ON_DRIFT=true; shift ;;
    --quiet)         QUIET=true; shift ;;
    --help|-h)       sed -n '/^#/p' "$0" | sed -n '1,40p'; exit 0 ;;
    *) echo "ERR: unknown arg $1" >&2; exit 2 ;;
  esac
done

[[ -d "$REPO_ROOT" ]] || { echo "ERR: repo root not found: $REPO_ROOT" >&2; exit 2; }

# ---- Helpers ---------------------------------------------------------------

log() { $QUIET || echo "$@"; }

# Latest mtime under a directory matching given glob patterns.
# Uses find -newer pivot so it works on macOS + Linux.
# Echoes seconds-since-epoch (or 0 if no matching files).
latest_mtime() {
  local dir="$1"; shift
  local patterns=("$@")
  local newest=0
  if [[ ! -d "$dir" ]]; then echo 0; return; fi
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local m
    # macOS stat -f %m / Linux stat -c %Y; try macOS first.
    m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
    if [[ "$m" -gt "$newest" ]]; then newest="$m"; fi
  done < <(find "$dir" -type f \( "${patterns[@]}" \) 2>/dev/null)
  echo "$newest"
}

list_repos() {
  if [[ -n "$SINGLE_REPO" ]]; then
    echo "${REPO_ROOT}/${SINGLE_REPO}"
    return
  fi
  find "${REPO_ROOT}" -maxdepth 1 -mindepth 1 -type d \
    \( -name 'zorbit-pfs-*' -o -name 'zorbit-app-*' \
       -o -name 'zorbit-ai-*' -o -name 'zorbit-cor-*' \
       -o -name 'sample-customer-service' \) \
    -print 2>/dev/null \
    | sort
}

fmt_age() {
  local epoch="$1"
  if [[ "$epoch" -eq 0 ]]; then echo "—"; return; fi
  local now age
  now=$(date +%s)
  age=$((now - epoch))
  if   [[ "$age" -lt 60   ]]; then echo "${age}s ago"
  elif [[ "$age" -lt 3600 ]]; then echo "$((age/60))m ago"
  elif [[ "$age" -lt 86400 ]]; then echo "$((age/3600))h ago"
  else echo "$((age/86400))d ago"; fi
}

# ---- Main ------------------------------------------------------------------

DRIFT_COUNT=0
NO_DIST_COUNT=0
OK_COUNT=0
SKIP_COUNT=0

log "check-source-dist-drift: scanning ${REPO_ROOT}"
log ""
if ! $QUIET; then
  printf "%-40s %-15s %-15s %-15s %s\n" "Repo" "Src newest" "Dist newest" "Status" "Detail"
  printf '%.0s-' {1..120}; echo
fi

while IFS= read -r repo; do
  [[ -z "$repo" || ! -d "$repo" ]] && continue
  repo_name="$(basename "$repo")"

  # Only check repos that actually have a src/ directory (TS/JS services).
  if [[ ! -d "$repo/src" ]]; then
    SKIP_COUNT=$((SKIP_COUNT+1))
    continue
  fi

  src_mt=$(latest_mtime "$repo/src" \
              -name '*.ts' -o -name '*.tsx' -o -name '*.js' \
              -o -name '*.jsx' -o -name '*.json')
  dist_mt=$(latest_mtime "$repo/dist" \
              -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.d.ts')

  src_age=$(fmt_age "$src_mt")
  dist_age=$(fmt_age "$dist_mt")

  if [[ "$dist_mt" -eq 0 ]]; then
    # No dist/ at all — not necessarily drift, but worth noting (will be
    # built by fresh-install before deploy). Mark as NO-DIST.
    NO_DIST_COUNT=$((NO_DIST_COUNT+1))
    if ! $QUIET; then
      printf "%-40s %-15s %-15s %-15s %s\n" \
        "$repo_name" "$src_age" "$dist_age" "NO-DIST" \
        "src present but dist/ missing — build required"
    fi
  elif [[ "$src_mt" -gt "$dist_mt" ]]; then
    DRIFT_COUNT=$((DRIFT_COUNT+1))
    delta_sec=$((src_mt - dist_mt))
    delta_str=$(fmt_age $((src_mt - delta_sec)))
    printf "%-40s %-15s %-15s %-15s %s\n" \
      "$repo_name" "$src_age" "$dist_age" "DRIFT" \
      "src newer than dist by ${delta_sec}s — run \`npm run build\`"
  else
    OK_COUNT=$((OK_COUNT+1))
    if ! $QUIET; then
      printf "%-40s %-15s %-15s %-15s %s\n" \
        "$repo_name" "$src_age" "$dist_age" "OK" \
        "dist >= src"
    fi
  fi
done < <(list_repos)

log ""
log "Summary: OK=${OK_COUNT}  DRIFT=${DRIFT_COUNT}  NO-DIST=${NO_DIST_COUNT}  SKIP=${SKIP_COUNT}"

if [[ "$DRIFT_COUNT" -gt 0 ]]; then
  echo "" >&2
  echo "WARNING: ${DRIFT_COUNT} repo(s) have src/ newer than dist/." >&2
  echo "         The deployed code will NOT reflect recent source changes." >&2
  echo "         Fix: cd <repo> && npm run build" >&2
  echo "" >&2
  if $FAIL_ON_DRIFT; then
    echo "FAIL: --fail-on-drift was set; exiting 1" >&2
    exit 1
  fi
fi

exit 0
