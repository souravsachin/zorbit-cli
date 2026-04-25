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

# -------------------------------------------------------------------------
# Preflight gate — fail fast if any Mongoose schema has a @Prop() decorator
# whose TS field type is ambiguous (union, any, Record<>) without `type:`.
# Such schemas crash NestJS at boot with CannotDetermineTypeError. Wired in
# 2026-04-25 by Soldier B after twice-daily fresh installs regressed.
# -------------------------------------------------------------------------
echo "==> Preflight: Mongoose @Prop() schema check"
bash "${SCRIPT_DIR}/preflight-mongoose-check.sh" \
  || { echo "FAILED preflight: fix offending @Prop() decorators above"; exit 1; }

# -------------------------------------------------------------------------
# Soldier C — silent-fail forensics (2026-04-25)
# Ran when ~15 services were stuck in a crash-restart loop with EMPTY pm2
# stderr but real boot-time errors. Each guard codifies one root cause so
# the next install fails LOUDLY rather than silently.
# -------------------------------------------------------------------------
echo "==> Preflight: silent-fail service guards"
bash "${SCRIPT_DIR}/preflight-services-check.sh" \
  || { echo "FAILED preflight: fix the silent-fail guards above"; exit 1; }

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
