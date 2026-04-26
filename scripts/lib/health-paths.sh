#!/usr/bin/env bash
# =============================================================================
# health-paths.sh — per-service health-endpoint resolution
# =============================================================================
# Background — Cycle 105 finding by soldier (n) (19:03 +07): the original
# probe assumed every service exposed a uniform /api/v1/G/<svc>/health path,
# so it false-flagged 17 services as unhealthy when they were actually fine
# at their declared paths.
#
# Reality (post-(m) deploy, 18:33 +07):
#   - 21 services now expose CANONICAL  /api/v1/G/health         (added by (m))
#   - Some services still ONLY expose legacy paths, e.g.:
#       zorbit-pfs-rtc            -> /api/v1/G/rtc/health
#       zorbit-pfs-workflow_engine-> /api/v1/G/workflow/health
#       zorbit-pfs-realtime       -> /api/v1/G/realtime/health
#       zorbit-pfs-secrets        -> /api/v1/G/secrets/health
#       zorbit-pfs-notification   -> /api/v1/G/notifications/health
#       zorbit-pfs-integration    -> /api/v1/G/integrations/health
#       zorbit-pfs-voice_engine   -> /api/v1/G/voice/health
#       zorbit-app-pcg5           -> /api/app/pcg5/v1/G/health
#       zorbit-app-claims_core    -> /api/v1/G/claims/health
#   - A few legacy one-offs encode the slug in @Controller (rare).
#
# Resolution strategy (canonical-first with legacy fallback):
#   1. Try CANONICAL /api/<slug>/api/v1/G/health  (works for 21+ services)
#   2. On 404, look up per-service path map (this file) and retry
#   3. On still-fail, declare unhealthy
#
# Source-of-truth precedence:
#   a. Per-service zorbit-module-manifest.json `health` field (declared by
#      module owner) — read at probe time when REPO_ROOT is set
#   b. Static fallback table (this file) — survives missing manifests
#
# Usage:
#   source health-paths.sh
#   path=$(resolve_health_path "<svc-name>" "<slug>")    # returns probe path
#   paths=$(resolve_health_paths_all "<svc-name>" "<slug>") # newline list
#
# =============================================================================

# Canonical path used by services updated post-(m) (Cycle 105 health-contract)
HEALTH_PATH_CANONICAL="/api/v1/G/health"

# Static fallback for services with non-canonical legacy paths.
# Format: "<service-name>=<legacy-path-suffix-after-slug-prefix>"
# These paths are appended AFTER the nginx /api/<slug>/ prefix.
declare -A HEALTH_PATH_LEGACY=(
  # Source: grep '@Controller.*health\|@Get.*health' across 02_repos/, 2026-04-26
  ["zorbit-pfs-rtc"]="/api/v1/G/rtc/health"
  ["zorbit-pfs-workflow_engine"]="/api/v1/G/workflow/health"
  ["zorbit-pfs-realtime"]="/api/v1/G/realtime/health"
  ["zorbit-pfs-secrets"]="/api/v1/G/secrets/health"
  ["zorbit-pfs-notification"]="/api/v1/G/notifications/health"
  ["zorbit-pfs-integration"]="/api/v1/G/integrations/health"
  ["zorbit-pfs-voice_engine"]="/api/v1/G/voice/health"
  ["zorbit-pfs-rules_engine"]="/v1/G/health"
  ["zorbit-pfs-pixel"]="/v1/G/health"
  ["zorbit-app-pcg5"]="/api/app/pcg5/v1/G/health"
  ["zorbit-app-claims_core"]="/api/v1/G/claims/health"
  ["zorbit-app-hi_policy_issue"]="/hi-policy-issue/api/v1/G/health"
  ["zorbit-app-hi_sme_uw_workflow"]="/hi-sme-uw-workflow/api/v1/G/health"
  ["zorbit-app-hi_claim_payment_recon"]="/v1/G/health"
  ["zorbit-pfs-api_integration"]="/api/api_integration/api/v1/G/health"
  ["zorbit-pfs-rpa_integration"]="/api/rpa_integration/api/v1/G/health"
)

# resolve_health_path <service-name> <slug>
# Echoes a single best-guess legacy path (if registered), else "" .
# This is the fallback when canonical /api/v1/G/health returns 404.
resolve_health_path_legacy() {
  local svc="$1"
  echo "${HEALTH_PATH_LEGACY[$svc]:-}"
}

# resolve_health_path_from_manifest <repo-root> <service-name>
# Reads zorbit-module-manifest.json for `health` field; echoes path or "".
# Manifests are the OWNER-DECLARED source of truth; static map is fallback.
resolve_health_path_from_manifest() {
  local repo_root="$1"
  local svc="$2"
  local manifest="${repo_root}/${svc}/zorbit-module-manifest.json"
  if [[ -f "$manifest" ]]; then
    python3 -c "
import json, sys
try:
    m = json.load(open('$manifest'))
    h = m.get('health')
    if h and isinstance(h, str):
        print(h)
except Exception:
    pass
" 2>/dev/null
  fi
}

# resolve_health_paths_all <service-name> <slug> [repo-root]
# Echo ordered candidate paths (canonical first, then manifest, then legacy).
# Caller probes each in order; first 200/204/401/403 wins.
resolve_health_paths_all() {
  local svc="$1"
  local slug="$2"
  local repo_root="${3:-}"
  # 1. Canonical (post-(m), most services have it)
  echo "${HEALTH_PATH_CANONICAL}"
  # 2. Manifest-declared
  if [[ -n "$repo_root" ]]; then
    local m
    m="$(resolve_health_path_from_manifest "$repo_root" "$svc")"
    if [[ -n "$m" && "$m" != "${HEALTH_PATH_CANONICAL}" ]]; then
      echo "$m"
    fi
  fi
  # 3. Static legacy table
  local legacy
  legacy="$(resolve_health_path_legacy "$svc")"
  if [[ -n "$legacy" && "$legacy" != "${HEALTH_PATH_CANONICAL}" ]]; then
    echo "$legacy"
  fi
}
