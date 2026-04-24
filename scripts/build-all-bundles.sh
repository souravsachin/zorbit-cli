#!/usr/bin/env bash
# =============================================================================
# build-all-bundles.sh
# =============================================================================
# Builds all 5 bundles (core, pfs, apps, ai, web) for one env via
# package-bundle.sh. Produces tarballs at:
#   /Users/s/workspace/zorbit/bundles/<VERSION>/<env>-<bundle>.tar.gz
#
# LAPTOP-LOCAL. No server writes.
#
# Usage:
#   bash build-all-bundles.sh --env ze --version v0.1.0
#   bash build-all-bundles.sh --env zq --version v0.1.0
#
# ~15-25 min total depending on node_modules cache warmth.
# =============================================================================
set -euo pipefail

ENV_PREFIX=""
VERSION=""
PLATFORM="linux/amd64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_PREFIX="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$ENV_PREFIX" || -z "$VERSION" ]] && { echo "usage: $0 --env ze --version v0.1.0"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BUNDLES=(core pfs apps ai web)

echo "==> Building ${#BUNDLES[@]} bundles for env=${ENV_PREFIX} version=${VERSION} platform=${PLATFORM}"
START=$(date +%s)

for b in "${BUNDLES[@]}"; do
  echo
  echo "---- BUNDLE: ${b} ----"
  BSTART=$(date +%s)
  bash "${SCRIPT_DIR}/package-bundle.sh" \
    --env "${ENV_PREFIX}" \
    --bundle "${b}" \
    --version "${VERSION}" \
    --platform "${PLATFORM}" \
    || { echo "FAILED on bundle ${b}"; exit 1; }
  BEND=$(date +%s)
  echo "  ${b} built in $((BEND - BSTART))s"
done

END=$(date +%s)
echo
echo "==> All 5 bundles built in $((END - START))s"
echo "Output: /Users/s/workspace/zorbit/bundles/${VERSION}/"
ls -lh "/Users/s/workspace/zorbit/bundles/${VERSION}/" 2>/dev/null || true
