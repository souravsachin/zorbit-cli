#!/usr/bin/env bash
# =============================================================================
# zorbit-cli/scripts/gates-harness.sh
# =============================================================================
# Parameterised L0-L7 gate runner.
# Based on the canonical UAT script:
#   zorbit-unified-console/testing/e2e-standalone-bundle/scripts/
#     zorbit-gate-checks-L0-L6.sh
#
# Differences:
#   - BASE_URL is taken from --base-url (was hard-coded)
#   - CONTAINER_PREFIX is derived from --env (ze|zq|zd|zu|zp)
#   - SHARED_PREFIX is always `zs-`
#   - EXPECTED_CONTAINERS + EXPECTED_MODULES come from bundles.yaml
#   - Writes a JSON report at /tmp/gates-<env>-<timestamp>.json
#   - Adds L7 hook (browser test via Playwright runner) — optional.
#
# Usage:
#   bash scripts/gates-harness.sh \
#        --env ze \
#        --base-url https://zorbit-dev.onezippy.ai \
#        [--gate L0]        # run only one gate
#        [--stop-on-fail]   # abort after first failure
#        [--json-only]      # suppress colour output, print JSON to stdout
#
# =============================================================================

set -euo pipefail

# ---- Args -------------------------------------------------------------------
ENV_PREFIX=""
BASE_URL=""
RUN_GATE=""
STOP_ON_FAIL=false
JSON_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)           ENV_PREFIX="$2"; shift 2 ;;
    --base-url)      BASE_URL="$2"; shift 2 ;;
    --gate)          RUN_GATE="$2"; shift 2 ;;
    --stop-on-fail)  STOP_ON_FAIL=true; shift ;;
    --json-only)     JSON_ONLY=true; shift ;;
    -h|--help)       sed -n '1,40p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "${ENV_PREFIX}" ]] && { echo "ERROR: --env required" >&2; exit 1; }
[[ -z "${BASE_URL}"   ]] && { echo "ERROR: --base-url required" >&2; exit 1; }

case "${ENV_PREFIX}" in
  ze|zq|zd|zu|zp) : ;;
  *) echo "ERROR: --env must be one of ze|zq|zd|zu|zp" >&2; exit 1 ;;
esac

SHARED_PREFIX="zs-"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
JSON_REPORT="/tmp/gates-${ENV_PREFIX}-${TIMESTAMP}.json"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/../.." && pwd)"
BUNDLES_YAML="${WORKSPACE_ROOT}/02_repos/zorbit-core/platform-spec/bundles.yaml"

[[ -f "${BUNDLES_YAML}" ]] || { echo "ERROR: bundles.yaml not found at ${BUNDLES_YAML}" >&2; exit 1; }

# ---- Colours ----------------------------------------------------------------
if ${JSON_ONLY}; then
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
else
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
fi

# ---- Derive EXPECTED_CONTAINERS and EXPECTED_MODULES from bundles.yaml -----
_BUNDLE_DUMP="$(python3 "${REPO_ROOT}/scripts/bootstrap-lib/_gates_bundle_dump.py" \
  "${BUNDLES_YAML}" "${ENV_PREFIX}")"
EXPECTED_CONTAINERS_STR="${_BUNDLE_DUMP%%|*}"
_REST="${_BUNDLE_DUMP#*|}"
EXPECTED_SHARED_STR="${_REST%%|*}"
EXPECTED_MODULES_STR="${_REST#*|}"

IFS=' ' read -ra EXPECTED_CONTAINERS <<< "${EXPECTED_CONTAINERS_STR}"
IFS=' ' read -ra EXPECTED_SHARED     <<< "${EXPECTED_SHARED_STR}"
IFS=' ' read -ra EXPECTED_MODULES    <<< "${EXPECTED_MODULES_STR}"
EXPECTED_MODULE_COUNT=${#EXPECTED_MODULES[@]}

# ---- State ------------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0
GATE_RESULTS=()
ACCESS_TOKEN=""
CHECK_RESULTS=()   # JSON rows for report

# ---- Helpers ----------------------------------------------------------------
_json_escape() {
  # Escape a string for embedding in JSON (handles quotes, backslashes, newlines).
  python3 -c 'import sys,json;print(json.dumps(sys.argv[1]))' "$1"
}
record_check() {
  local result="$1" desc="$2"
  local esc
  esc="$(_json_escape "${desc}")"
  CHECK_RESULTS+=("{\"gate\":\"${CURRENT_GATE:-}\",\"result\":\"${result}\",\"desc\":${esc}}")
}
pass()  { echo -e "  ${GREEN}[PASS]${RESET} $1"; PASS=$((PASS+1)); record_check pass "$1"; }
fail()  { echo -e "  ${RED}[FAIL]${RESET} $1";  FAIL=$((FAIL+1)); record_check fail "$1"; }
info()  { echo -e "  ${CYAN}[i]${RESET}  $1"; }
warn()  { echo -e "  ${YELLOW}[!]${RESET}  $1"; }
gate_header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${RESET}"; }
check_stop() { if $STOP_ON_FAIL && [[ $FAIL -gt 0 ]]; then summary; write_json; exit 1; fi; }
should_run() { [[ -z "${RUN_GATE}" || "${RUN_GATE}" == "$1" ]]; }
http_status() { curl -sk -o /dev/null -w "%{http_code}" "$1" "${@:2}"; }
http_body()   { curl -sk "$1" "${@:2}"; }

record_gate() {
  local gate="$1" pfail="$2"
  if [[ $pfail -eq 0 ]]; then
    GATE_RESULTS+=("${GREEN}[OK]${RESET} ${gate}")
  else
    GATE_RESULTS+=("${RED}[FAIL]${RESET} ${gate} (${pfail} checks failed)")
  fi
}

write_json() {
  local joined
  joined=$(IFS=, ; echo "${CHECK_RESULTS[*]}")
  cat > "${JSON_REPORT}" <<JSON
{
  "env": "${ENV_PREFIX}",
  "base_url": "${BASE_URL}",
  "timestamp": "${TIMESTAMP}",
  "summary": { "pass": ${PASS}, "fail": ${FAIL}, "skip": ${SKIP} },
  "expected_containers": [$(printf '"%s",' "${EXPECTED_CONTAINERS[@]}" | sed 's/,$//')],
  "expected_shared":     [$(printf '"%s",' "${EXPECTED_SHARED[@]}"     | sed 's/,$//')],
  "expected_modules":    [$(printf '"%s",' "${EXPECTED_MODULES[@]}"    | sed 's/,$//')],
  "checks": [${joined}]
}
JSON
  echo -e "\n${CYAN}JSON report: ${JSON_REPORT}${RESET}"
}

summary() {
  echo -e "\n${BOLD}=== Gate Summary (env=${ENV_PREFIX}) ===${RESET}"
  for r in "${GATE_RESULTS[@]}"; do echo -e "  $r"; done
  echo -e "${BOLD}---------------------------------------${RESET}"
  echo -e "  ${GREEN}PASS: ${PASS}${RESET}   ${RED}FAIL: ${FAIL}${RESET}   ${YELLOW}SKIP: ${SKIP}${RESET}"
  if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}ALL GATES PASSED${RESET}"
  else
    echo -e "  ${RED}${BOLD}${FAIL} FAILURE(S) — see above${RESET}"
  fi
}

# =============================================================================
# L0 — Docker Containers + Networks
# =============================================================================
if should_run "L0"; then
  CURRENT_GATE="L0"
  gate_header "L0 - Docker Infrastructure"
  before=${FAIL}

  RUNNING="$(docker ps --format '{{.Names}}' 2>/dev/null || echo '')"

  # Bundle containers
  for cname in "${EXPECTED_CONTAINERS[@]}"; do
    if echo "${RUNNING}" | grep -qx "${cname}"; then
      pass "Bundle container running: ${cname}"
    else
      fail "Bundle container NOT running: ${cname}"
    fi
  done

  # Shared infra
  for cname in "${EXPECTED_SHARED[@]}"; do
    if echo "${RUNNING}" | grep -qx "${cname}"; then
      pass "Shared infra running: ${cname}"
    else
      fail "Shared infra NOT running: ${cname}"
    fi
  done

  # PM2 process inside core
  if docker exec "${ENV_PREFIX}-core" pm2 list 2>/dev/null | grep -qE 'zorbit-identity'; then
    pass "PM2 inside ${ENV_PREFIX}-core: zorbit-identity running"
  else
    fail "PM2 inside ${ENV_PREFIX}-core: zorbit-identity NOT found"
  fi

  record_gate "L0 - Docker Infrastructure" $((FAIL - before))
  check_stop
fi

# =============================================================================
# L1 — Service Health Endpoints (external HTTPS)
# =============================================================================
if should_run "L1"; then
  CURRENT_GATE="L1"
  gate_header "L1 - Service Health"
  before=${FAIL}

  declare -A HEALTH_ENDPOINTS=(
    ["identity"]="/api/identity/api/v1/G/health"
    ["authorization"]="/api/authorization/api/v1/G/health"
    ["navigation"]="/api/navigation/api/v1/G/health"
    ["module-registry"]="/api/module-registry/api/v1/G/health"
    ["event-bus"]="/api/event-bus/api/v1/G/health"
    ["audit"]="/api/audit/api/v1/G/health"
    ["pii-vault"]="/api/pii-vault/api/v1/G/health"
  )

  for svc in "${!HEALTH_ENDPOINTS[@]}"; do
    path="${HEALTH_ENDPOINTS[$svc]}"
    status=$(http_status "${BASE_URL}${path}")
    if [[ "${status}" == "200" ]]; then
      pass "Health OK (${status}): ${svc} -> ${path}"
    else
      fail "Health FAIL (${status}): ${svc} -> ${path}"
    fi
  done

  record_gate "L1 - Service Health" $((FAIL - before))
  check_stop
fi

# =============================================================================
# L2 — Auth + JWT Structure
# =============================================================================
if should_run "L2"; then
  CURRENT_GATE="L2"
  gate_header "L2 - Auth + JWT"
  before=${FAIL}

  ADMIN_EMAIL="${ADMIN_EMAIL:-s@onezippy.ai}"
  ADMIN_PASS="${ADMIN_PASS:-s@2021#cz}"

  LOGIN_RESP="$(http_body "${BASE_URL}/api/identity/api/v1/G/auth/login" \
      -X POST -H "Content-Type: application/json" \
      -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\"}" 2>/dev/null || echo '{}')"

  if echo "${LOGIN_RESP}" | grep -q '"accessToken"'; then
    pass "Login returns accessToken"
    ACCESS_TOKEN="$(echo "${LOGIN_RESP}" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)"
  else
    fail "Login did NOT return accessToken"
  fi

  if [[ -n "${ACCESS_TOKEN}" ]]; then
    JWT_PAYLOAD="$(echo "${ACCESS_TOKEN}" | cut -d'.' -f2 | \
      awk '{n=length($0)%4; if(n==2) $0=$0"=="; if(n==3) $0=$0"="; print}' | \
      base64 -d 2>/dev/null || echo '{}')"
    echo "${JWT_PAYLOAD}" | grep -q '"org"' && pass "JWT payload has org field" || fail "JWT payload missing org field"
    echo "${JWT_PAYLOAD}" | grep -q '"privileges":\[' && pass "JWT payload has privileges array" || fail "JWT payload missing privileges"
  fi

  record_gate "L2 - Auth + JWT" $((FAIL - before))
  check_stop
fi

# =============================================================================
# L3 — Kafka Topics + Consumer Groups
# =============================================================================
if should_run "L3"; then
  CURRENT_GATE="L3"
  gate_header "L3 - Kafka"
  before=${FAIL}

  KAFKA_CONTAINER="${SHARED_PREFIX}kafka"
  for topic in platform-module-announcements platform-module-ready; do
    if docker exec "${KAFKA_CONTAINER}" /usr/bin/kafka-topics.sh \
         --bootstrap-server localhost:9092 --list 2>/dev/null | grep -qx "${topic}"; then
      pass "Kafka topic exists: ${topic}"
    else
      fail "Kafka topic MISSING: ${topic}"
    fi
  done

  record_gate "L3 - Kafka" $((FAIL - before))
  check_stop
fi

# =============================================================================
# L4 — Module Registry API State
# =============================================================================
if should_run "L4"; then
  CURRENT_GATE="L4"
  gate_header "L4 - Module Registry"
  before=${FAIL}

  if [[ -z "${ACCESS_TOKEN}" ]]; then
    warn "No ACCESS_TOKEN — skipping L4"
    SKIP=$((SKIP + 1))
    record_gate "L4 - Module Registry" 0
  else
    RESP="$(http_body "${BASE_URL}/api/module-registry/api/v1/G/modules" \
               -H "Authorization: Bearer ${ACCESS_TOKEN}" 2>/dev/null || echo '[]')"
    status="$(http_status "${BASE_URL}/api/module-registry/api/v1/G/modules" \
               -H "Authorization: Bearer ${ACCESS_TOKEN}")"
    [[ "${status}" == "200" ]] && pass "Registry API returns 200" || fail "Registry API status ${status}"

    READY_COUNT="$(echo "${RESP}" | grep -o '"status":"READY"' | wc -l | tr -d ' ')"
    TOTAL_COUNT="$(echo "${RESP}" | grep -o '"moduleId"' | wc -l | tr -d ' ')"
    info "Registry: ${TOTAL_COUNT} total modules, ${READY_COUNT} READY"

    if [[ "${READY_COUNT}" -ge "${EXPECTED_MODULE_COUNT}" ]]; then
      pass "All ${EXPECTED_MODULE_COUNT}+ modules READY (${READY_COUNT})"
    elif [[ "${READY_COUNT}" -gt 0 ]]; then
      fail "Only ${READY_COUNT} / ${EXPECTED_MODULE_COUNT} modules READY"
    else
      fail "Zero READY modules"
    fi

    record_gate "L4 - Module Registry" $((FAIL - before))
    check_stop
  fi
fi

# =============================================================================
# L5 — Kafka Event Flow (publish -> nav logs cached)
# =============================================================================
if should_run "L5"; then
  CURRENT_GATE="L5"
  gate_header "L5 - Kafka Event Flow"
  before=${FAIL}

  info "L5 requires an inside-container pub script. Skipping if not present."
  if docker exec "${ENV_PREFIX}-core" test -f /app/pub_module_ready.js 2>/dev/null; then
    pass "Pub script present inside ${ENV_PREFIX}-core"
  else
    warn "No pub script baked into ${ENV_PREFIX}-core image — L5 skipped (info)"
    SKIP=$((SKIP + 1))
  fi

  record_gate "L5 - Kafka Event Flow" $((FAIL - before))
  check_stop
fi

# =============================================================================
# L6 — Navigation Cache (/menu)
# =============================================================================
if should_run "L6"; then
  CURRENT_GATE="L6"
  gate_header "L6 - Navigation Cache"
  before=${FAIL}

  if [[ -z "${ACCESS_TOKEN}" ]]; then
    warn "No ACCESS_TOKEN — skipping L6"
    SKIP=$((SKIP + 1))
    record_gate "L6 - Navigation Cache" 0
  else
    JWT_PAYLOAD="$(echo "${ACCESS_TOKEN}" | cut -d'.' -f2 | \
      awk '{n=length($0)%4; if(n==2) $0=$0"=="; if(n==3) $0=$0"="; print}' | \
      base64 -d 2>/dev/null || echo '{}')"
    USER_ID="$(echo "${JWT_PAYLOAD}" | grep -o '"sub":"[^"]*"' | cut -d'"' -f4 || echo '')"

    if [[ -z "${USER_ID}" ]]; then
      fail "Cannot determine user ID from JWT"
    else
      MENU_URL="${BASE_URL}/api/navigation/api/v1/U/${USER_ID}/navigation/menu"
      status="$(http_status "${MENU_URL}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
      [[ "${status}" == "200" ]] && pass "Menu returns 200" || fail "Menu status ${status}"
    fi

    record_gate "L6 - Navigation Cache" $((FAIL - before))
    check_stop
  fi
fi

# =============================================================================
# L7 — Browser smoke test (optional, Playwright runner)
# =============================================================================
if should_run "L7"; then
  CURRENT_GATE="L7"
  gate_header "L7 - Browser UI"
  before=${FAIL}
  warn "L7 runs via Playwright runner — not executed inline. See:"
  warn "  cd ${WORKSPACE_ROOT}/02_repos/zorbit-unified-console/testing/e2e-standalone-bundle"
  warn "  npx ts-node runner.ts --config configs/zorbit-gate-checks.json --bouquet gate"
  SKIP=$((SKIP + 1))
  record_gate "L7 - Browser UI" $((FAIL - before))
fi

# =============================================================================
# Summary + JSON
# =============================================================================
summary
write_json

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
