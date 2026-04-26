#!/usr/bin/env bash
# =============================================================================
# push-bundles-to-ghcr.sh
# =============================================================================
# Tag locally-built bundle images and push them to ghcr.io/souravsachin so
# every Zorbit environment (zorbit-{dev,qa,demo,uat,prod}) can pull them
# without needing to ship tarballs.
#
# Companion to build-all-bundles.sh + package-bundle.sh.
#
# Pre-requisites:
#   - 5 bundle images already built locally:
#       zorbit-core:<version>
#       zorbit-pfs:<version>
#       zorbit-apps:<version>
#       zorbit-ai:<version>
#       zorbit-web:<version>
#     plus the build-time base image:
#       zorbit-pm2-base:1.0
#   - gh CLI logged in with `write:packages` scope, OR a GitHub PAT exported
#     via `GH_TOKEN=<pat>` with the same scope.
#
# Usage:
#   bash push-bundles-to-ghcr.sh --version v0.1.0
#   bash push-bundles-to-ghcr.sh --version v0.1.0 --extra-tag v0.1.0-20260425
#
# Image refs created (each bundle):
#   ghcr.io/souravsachin/zorbit-<bundle>:<version>
#   ghcr.io/souravsachin/zorbit-<bundle>:latest
#   ghcr.io/souravsachin/zorbit-<bundle>:<extra-tag>     (optional)
#
# pm2-base is pushed as 1.0 + latest (no version arg).
#
# Exit codes:
#   0 = all images pushed
#   1 = missing arg or precondition failed
#   2 = docker login failed
#   3 = a push failed
# =============================================================================
set -euo pipefail

VERSION=""
EXTRA_TAG=""
REGISTRY="ghcr.io/souravsachin"
BUNDLES=(core pfs apps ai web)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --extra-tag) EXTRA_TAG="$2"; shift 2 ;;
    --registry)  REGISTRY="$2"; shift 2 ;;
    -h|--help)   sed -n '1,50p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$VERSION" ]] && { echo "ERROR: --version required (e.g. v0.1.0)"; exit 1; }

log() { printf "[push-bundles] %s\n" "$*"; }

# ---- Precondition: all 5 bundles + pm2-base exist locally ------------------
log "Verifying local images exist..."
MISSING=()
for b in "${BUNDLES[@]}"; do
  ref="zorbit-${b}:${VERSION}"
  docker image inspect "$ref" >/dev/null 2>&1 || MISSING+=("$ref")
done
docker image inspect "zorbit-pm2-base:1.0" >/dev/null 2>&1 || MISSING+=("zorbit-pm2-base:1.0")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  log "MISSING local images:"; printf "  - %s\n" "${MISSING[@]}"
  log "Run: bash build-all-bundles.sh --env ze --version ${VERSION}  first"
  exit 1
fi
log "All 6 local images present"

# ---- Login to ghcr.io ------------------------------------------------------
TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null || echo '')}"
[[ -z "$TOKEN" ]] && { echo "ERROR: no GH_TOKEN env and gh CLI not logged in"; exit 2; }
echo "$TOKEN" | docker login "${REGISTRY%%/*}" -u souravsachin --password-stdin \
  || { echo "ERROR: docker login failed"; exit 2; }

# ---- Tag + push every image ------------------------------------------------
push_one() {
  local src="$1"; local dst="$2"
  log "  push ${dst}"
  docker tag "$src" "$dst"
  docker push "$dst" 2>&1 | tail -1 || return 3
}

for b in "${BUNDLES[@]}"; do
  log "=== ${b} ==="
  src="zorbit-${b}:${VERSION}"
  push_one "$src" "${REGISTRY}/zorbit-${b}:${VERSION}"
  push_one "$src" "${REGISTRY}/zorbit-${b}:latest"
  [[ -n "$EXTRA_TAG" ]] && push_one "$src" "${REGISTRY}/zorbit-${b}:${EXTRA_TAG}"
done

log "=== pm2-base ==="
push_one "zorbit-pm2-base:1.0" "${REGISTRY}/zorbit-pm2-base:1.0"
push_one "zorbit-pm2-base:1.0" "${REGISTRY}/zorbit-pm2-base:latest"

log "Done. All images pushed to ${REGISTRY}/"
log "Verify: gh api 'user/packages?package_type=container' | grep zorbit"
