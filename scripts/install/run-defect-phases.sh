#!/usr/bin/env bash
# =============================================================================
# scripts/install/run-defect-phases.sh
#
# Top-level orchestrator that runs the D1..D9 phases in order. Wired into
# layer-6-post-deploy.sh (after super-admin seed) so any new env spin-up
# gets the full chain — preflight gates first, then seed-everything, then
# verify-e2e gate that aborts on fail.
#
# Inputs:
#   ENV_PREFIX           REQUIRED
#   IMAGE_TAG            REQUIRED for D1
#   SUPER_ADMINS_JSON    REQUIRED for D5/D6
#   SUPER_ADMIN_EMAIL    REQUIRED for D9
#   SUPER_ADMIN_PASSWORD REQUIRED for D9
#   ADMIN_JWT            optional — captured from D9 login if absent
#   PUBLIC_URL           default https://zorbit-${ENV_PREFIX}.onezippy.ai
#   SSH_TARGET           default ''
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PREFIX="${ENV_PREFIX:-${1:-}}"
[[ -z "$ENV_PREFIX" ]] && { echo "ERR: ENV_PREFIX required"; exit 1; }

REPORT_DIR="${ZORBIT_INSTALL_LOG_DIR:-/var/log/zorbit-install}"
mkdir -p "$REPORT_DIR" 2>/dev/null || REPORT_DIR=/tmp
export ZORBIT_INSTALL_LOG_DIR="$REPORT_DIR"

run_phase() {
  local script="$1" label="$2"
  echo
  echo "============================================================"
  echo " phase: $label"
  echo "============================================================"
  if bash "$script"; then
    echo "  PHASE OK: $label"
    return 0
  else
    rc=$?
    echo "  PHASE FAILED ($rc): $label"
    return $rc
  fi
}

# D1 — image freshness (skip if IMAGE_TAG unset, but warn)
if [[ -n "${IMAGE_TAG:-}" ]]; then
  run_phase "${SCRIPT_DIR}/preflight-image-freshness.sh" "D1 image-freshness" || exit $?
else
  echo "WARN: IMAGE_TAG unset — skipping D1 (not recommended)"
fi

# D2 — sdk versions
run_phase "${SCRIPT_DIR}/preflight-sdk-versions.sh" "D2 sdk-versions" || exit $?

# D3 — seed authz catalog
run_phase "${SCRIPT_DIR}/seed-authz-catalog.sh" "D3 seed-authz-catalog" || exit $?

# D4 — seed authz roles
run_phase "${SCRIPT_DIR}/seed-authz-roles.sh" "D4 seed-authz-roles" || exit $?

# D5 + D6 — seed super admins (writes both tables + sets users.role)
run_phase "${SCRIPT_DIR}/seed-super-admins.sh" "D5+D6 seed-super-admins" || exit $?

# Now login once to get an ADMIN_JWT for downstream phases
if [[ -z "${ADMIN_JWT:-}" ]]; then
  pwd_hash=$(printf '%s' "${SUPER_ADMIN_PASSWORD}" | shasum -a 256 2>/dev/null | awk '{print $1}')
  [[ -z "$pwd_hash" ]] && pwd_hash=$(printf '%s' "${SUPER_ADMIN_PASSWORD}" | sha256sum | awk '{print $1}')
  login_body=$(jq -nc --arg e "$SUPER_ADMIN_EMAIL" --arg p "$pwd_hash" '{email:$e, password:$p}')
  PUBLIC_URL="${PUBLIC_URL:-https://zorbit-${ENV_PREFIX}.onezippy.ai}"
  resp=$(curl -sS -m 20 -X POST "${PUBLIC_URL}/api/identity/api/v1/G/auth/login" \
    -H 'Content-Type: application/json' --data "$login_body" 2>/dev/null || echo "{}")
  ADMIN_JWT=$(echo "$resp" | jq -r '.accessToken // .access_token // .token // empty' 2>/dev/null)
  ADMIN_UHID=$(echo "$resp" | jq -r '.user.hashId // .user.id // empty' 2>/dev/null)
  export ADMIN_JWT ADMIN_USER_HASH_ID="$ADMIN_UHID"
fi
[[ -z "${ADMIN_JWT:-}" ]] && { echo "FATAL: cannot obtain ADMIN_JWT to drive D7/D8"; exit 1; }

# D7 — register all modules
run_phase "${SCRIPT_DIR}/register-all-modules.sh" "D7 register-all-modules" || exit $?

# D8 — prime navigation cache
run_phase "${SCRIPT_DIR}/prime-navigation-cache.sh" "D8 prime-navigation-cache" || exit $?

# D9 — verify e2e (abort gate)
run_phase "${SCRIPT_DIR}/verify-e2e.sh" "D9 verify-e2e (abort gate)" || exit $?

echo
echo "============================================================"
echo " ALL D1..D9 phases PASSED — env genuinely usable"
echo "============================================================"
