#!/usr/bin/env bash
# =============================================================================
# preflight-sdk-lock-sync.sh
# =============================================================================
# Verifies that every consumer's package-lock.json records the SAME
# @zorbit-platform/sdk-node version that the local zorbit-sdk-node repo
# currently has. Mismatch causes `npm ci` to abort with EUSAGE — silent
# at lock generation time, loud at bundle build time.
#
# Auto-detects the workspace root from script location.
#
# Failure modes caught:
#   - lock file recorded sdk-node 0.1.0 but the linked repo has 0.5.3
#   - lock file missing the sdk-node entry entirely
#
# Auto-fixes when run with `--fix`: regenerates each stale lock file with
# `npm install --package-lock-only` after wiping node_modules.
#
# Wired into build-all-bundles.sh — runs after the existing preflights.
#
# (qq) installer-improvement fix per MSG-107.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/../.." && pwd)"
SDK_PKG="${WORKSPACE_ROOT}/02_repos/zorbit-sdk-node/package.json"
FIX_MODE="false"

[[ "${1:-}" == "--fix" ]] && FIX_MODE="true"

if [[ ! -f "$SDK_PKG" ]]; then
  echo "preflight-sdk-lock: zorbit-sdk-node not found at $SDK_PKG"
  exit 0  # not in this checkout
fi

SDK_VER=$(python3 -c "import json; print(json.load(open('$SDK_PKG'))['version'])")
echo "preflight-sdk-lock: workspace SDK version = $SDK_VER"

STALE_REPOS=()
for r in "${WORKSPACE_ROOT}/02_repos"/zorbit-pfs-* \
         "${WORKSPACE_ROOT}/02_repos"/zorbit-app-* \
         "${WORKSPACE_ROOT}/02_repos"/sample-customer-service \
         "${WORKSPACE_ROOT}/02_repos"/zorbit-portal-*; do
  [[ -d "$r" ]] || continue
  [[ -f "$r/package.json" ]] || continue
  grep -q "@zorbit-platform/sdk-node" "$r/package.json" 2>/dev/null || continue
  if [[ ! -f "$r/package-lock.json" ]]; then
    STALE_REPOS+=("$r")
    continue
  fi
  recorded=$(grep -A2 "@zorbit-platform/sdk-node" "$r/package-lock.json" 2>/dev/null \
             | grep version | head -1 | sed 's/.*"\(.*\)".*/\1/')
  if [[ "$recorded" != "$SDK_VER" ]]; then
    STALE_REPOS+=("$r")
    echo "preflight-sdk-lock: STALE $(basename "$r") (lock=$recorded, sdk=$SDK_VER)"
    continue
  fi
  # Even if the version matches, npm ci ALSO requires a "../zorbit-sdk-node"
  # workspace root entry. Without it, `npm ci` aborts with "Missing X@Y from
  # lock file". --package-lock-only doesn't materialise this entry, so we
  # have to explicitly verify it. (qq) 2026-04-27.
  if ! grep -q '"../zorbit-sdk-node":' "$r/package-lock.json" 2>/dev/null; then
    STALE_REPOS+=("$r")
    echo "preflight-sdk-lock: INCOMPLETE $(basename "$r") (lock missing '../zorbit-sdk-node' workspace entry)"
  fi
done

if [[ ${#STALE_REPOS[@]} -eq 0 ]]; then
  echo "preflight-sdk-lock: OK — all consumer locks match sdk-node@${SDK_VER}"
  exit 0
fi

echo "preflight-sdk-lock: ${#STALE_REPOS[@]} stale lock file(s)"
if [[ "$FIX_MODE" != "true" ]]; then
  echo "preflight-sdk-lock: re-run with --fix to regenerate, or run:"
  for r in "${STALE_REPOS[@]}"; do
    echo "  (cd $r && rm -rf node_modules package-lock.json && npm install --no-audit --no-fund)"
  done
  exit 1
fi

echo "preflight-sdk-lock: regenerating ${#STALE_REPOS[@]} lock files..."
# IMPORTANT: use full `npm install --install-links=false` (NOT
# --package-lock-only, NOT default --install-links=true). `npm ci`
# validates that file:.. workspace packages have a matching root entry
# in the lock (e.g. "../zorbit-sdk-node": {...}). Reasons each variant
# of this command DOES NOT work:
#   - --package-lock-only: doesn't materialise the workspace entry.
#   - default install-links=true: COPIES the linked dep into
#     node_modules and DROPS the workspace lock entry.
#   - default install-links=true: lock passes preflight but `npm ci`
#     in the docker layer aborts with EUSAGE "Missing X@Y from lock file"
#     because the workspace entry is gone.
# Only `npm install --install-links=false` produces a lock that satisfies
# `npm ci` for a file:.. workspace package. (qq) 2026-04-27.
for r in "${STALE_REPOS[@]}"; do
  echo "  $(basename "$r")"
  (cd "$r" && rm -rf node_modules package-lock.json && \
    npm install --install-links=false --no-audit --no-fund > /tmp/regen-$(basename "$r").log 2>&1) \
    || { echo "    FAIL — see /tmp/regen-$(basename "$r").log"; exit 1; }
done
echo "preflight-sdk-lock: OK — regenerated"
