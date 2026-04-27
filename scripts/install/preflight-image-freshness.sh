#!/usr/bin/env bash
# =============================================================================
# scripts/install/preflight-image-freshness.sh    [D1]
#
# Defect D1: zq env was deployed with `ghcr.io/.../zorbit-core:v0.1.0` —
# an image built BEFORE the JWT-SLIM merge. Login worked but issued JWTs
# without `privilege_set_hash`, so SPA's privilege gate had no key. End
# result: super-admin → /no-access redirect.
#
# This preflight FAILS LOUD if the image referenced by IMAGE_TAG is older
# than IMAGE_MAX_AGE_HOURS (default 24). Forces a fresh rebuild rather
# than silent regression.
#
# Inputs (env or args):
#   IMAGE_REGISTRY_BASE     default: ghcr.io/souravsachin
#   IMAGE_TAG               REQUIRED — e.g. v0.1.1-20260427-1730
#   IMAGE_MAX_AGE_HOURS     default: 24
#   BUNDLES                 default: "core pfs apps ai web"
#
# Exit codes:
#   0  fresh enough
#   1  one or more images stale or missing
#   2  cannot reach registry
# =============================================================================
set -euo pipefail

REGISTRY_BASE="${IMAGE_REGISTRY_BASE:-ghcr.io/souravsachin}"
TAG="${IMAGE_TAG:-}"
MAX_AGE_H="${IMAGE_MAX_AGE_HOURS:-24}"
BUNDLES_LIST="${BUNDLES:-core pfs apps ai web}"
REPORT_DIR="${ZORBIT_INSTALL_LOG_DIR:-/var/log/zorbit-install}"
mkdir -p "$REPORT_DIR" 2>/dev/null || REPORT_DIR=/tmp

[[ -z "$TAG" ]] && { echo "ERR: IMAGE_TAG required"; exit 2; }

now_epoch=$(date -u +%s)
max_age_s=$((MAX_AGE_H * 3600))
fail=0
report_entries=()

for b in $BUNDLES_LIST; do
  ref="${REGISTRY_BASE}/zorbit-${b}:${TAG}"
  echo "==> checking $ref"
  # Try docker manifest inspect (works for ghcr if logged in)
  raw=$(docker manifest inspect "$ref" 2>&1 || true)
  created=""
  if echo "$raw" | grep -q '"created"'; then
    created=$(echo "$raw" | grep -oE '"created":[^,]+' | head -1 | sed 's/.*"\(.*\)"/\1/')
  fi
  # Fallback: pull and inspect
  if [[ -z "$created" ]]; then
    docker pull "$ref" >/dev/null 2>&1 || { echo "  CANNOT pull $ref"; fail=1; report_entries+=("\"${b}\":{\"status\":\"unreachable\"}"); continue; }
    created=$(docker inspect -f '{{.Created}}' "$ref" 2>/dev/null || echo "")
  fi
  if [[ -z "$created" ]]; then
    echo "  CANNOT determine creation date for $ref"
    fail=1
    report_entries+=("\"${b}\":{\"status\":\"no_metadata\"}")
    continue
  fi
  # epoch from RFC3339
  created_epoch=$(date -u -d "$created" +%s 2>/dev/null || python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$created'.replace('Z','+00:00')).timestamp()))" 2>/dev/null || echo 0)
  age_s=$((now_epoch - created_epoch))
  age_h=$((age_s / 3600))
  if (( age_s > max_age_s )); then
    echo "  STALE: ${ref} is ${age_h}h old (limit ${MAX_AGE_H}h)"
    fail=1
    report_entries+=("\"${b}\":{\"status\":\"stale\",\"age_hours\":${age_h}}")
  else
    echo "  ok: ${ref} is ${age_h}h old"
    report_entries+=("\"${b}\":{\"status\":\"fresh\",\"age_hours\":${age_h}}")
  fi
done

# Write JSON report
report_file="${REPORT_DIR}/preflight-image-freshness.json"
{
  printf '{"phase":"preflight-image-freshness","tag":"%s","max_age_hours":%s,"bundles":{' \
    "$TAG" "$MAX_AGE_H"
  IFS=,; printf '%s' "${report_entries[*]}"; unset IFS
  printf '},"result":"%s"}\n' "$([[ $fail -eq 0 ]] && echo pass || echo fail)"
} > "$report_file" || true

if (( fail )); then
  echo
  echo "==> D1 preflight FAILED — at least one bundle image is stale or unreachable."
  echo "    Re-run build-all-bundles.sh + push-bundles-to-ghcr.sh with a fresh dated tag."
  exit 1
fi

echo "==> D1 preflight PASS — all ${BUNDLES_LIST} images < ${MAX_AGE_H}h old"
exit 0
