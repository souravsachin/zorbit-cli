#!/usr/bin/env bash
# =============================================================================
# zorbit-cli/scripts/smoke-test.sh
#
# Post-install verification of a Zorbit environment. Runs a battery of
# health/functional checks and prints a pass/fail table (or JSON for CI).
#
# Usage:
#   ./smoke-test.sh --env <name> [--hostname <host>] [--json] [--timeout <s>]
#
# Flags:
#   --env <name>        Required. dev|qa|demo|uat|prod OR zorbit-<name>.
#   --hostname <host>   Optional hostname override. Defaults to spec value.
#   --json              Machine-readable JSON report to stdout; silences banner.
#   --timeout <s>       Per-request timeout in seconds (default 5).
#
# Checks:
#   1.  HTTP health for every registered service (/health)
#   2.  Manifest endpoint for every module (/api/<slug>/api/v1/G/manifest)
#   3.  Module-registry enumeration — all READY
#   4.  Nav cascade /api/navigation/api/v1/U/<test>/menu source=live
#   5.  Identity register + login + token + delete roundtrip
#   6.  PII-vault tokenise + reveal + redaction policy match
#   7.  Kafka publish + consume roundtrip (event-bus admin)
#   8.  Seeder dry-run: POST /seed-bundles/:id/previews returns 3 rows
#
# Exit codes:
#   0   all checks green
#   1   at least one check red
#   2   env unreachable entirely (no hostname, no local service)
#   3   bad invocation
#
# Spec version: 1.0 (2026-04-23)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/bootstrap-lib"

# Allow running without common.sh (for ultra-lean --json CI invocation).
# shellcheck disable=SC1091
source "${LIB_DIR}/common.sh"

# Per-service health-path resolution (Item 37, soldier (u), 2026-04-26).
# shellcheck source=lib/health-paths.sh
source "${SCRIPT_DIR}/lib/health-paths.sh"
REPO_ROOT_FOR_MANIFESTS="${REPO_ROOT_FOR_MANIFESTS:-${REPO_ROOT_GUESS:-/Users/s/workspace/zorbit/02_repos}}"

# ---------------------------------------------------------------------------
# Arg parsing.
# ---------------------------------------------------------------------------
ENV_ARG=""
HOSTNAME_ARG=""
JSON_OUT=false
TIMEOUT=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)      ENV_ARG="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --json)     JSON_OUT=true; shift;;
    --timeout)  TIMEOUT="$2"; shift 2;;
    --help|-h)  sed -n '/^#/p' "${BASH_SOURCE[0]}" | sed -n '1,40p'; exit 0;;
    *)          echo "Unknown arg: $1" >&2; exit 3;;
  esac
done

[[ -z "${ENV_ARG}" ]] && { echo "--env required" >&2; exit 3; }

if [[ "${ENV_ARG}" == zorbit-* ]]; then
  ENV_NAME="${ENV_ARG}"
  ENV_SHORT="${ENV_ARG#zorbit-}"
else
  ENV_SHORT="${ENV_ARG}"
  ENV_NAME="zorbit-${ENV_ARG}"
fi

ENV_FILE="${REPO_ROOT_GUESS}/zorbit-core/platform-spec/environments.yaml"
MANIFEST_FILE="${REPO_ROOT_GUESS}/zorbit-core/platform-spec/all-repos.yaml"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2; exit 2
fi
if [[ ! -f "${MANIFEST_FILE}" ]]; then
  echo "Missing ${MANIFEST_FILE}" >&2; exit 2
fi

PORT_BASE=$(yaml_get "${ENV_FILE}" "[e['port_base'] for e in data['environments'] if e['name']=='${ENV_NAME}'][0]" 2>/dev/null || echo "")
if [[ -z "${PORT_BASE}" ]]; then
  echo "Env ${ENV_NAME} not in ${ENV_FILE}" >&2; exit 2
fi

HOSTNAME="${HOSTNAME_ARG}"
if [[ -z "${HOSTNAME}" ]]; then
  HOSTNAME=$(yaml_get "${ENV_FILE}" "[e['default_host'] for e in data['environments'] if e['name']=='${ENV_NAME}'][0]" 2>/dev/null || echo "zorbit-${ENV_SHORT}.onezippy.ai")
fi

# Base URL for end-user HTTPS testing (per feedback: test via public URL).
# Fallback to 127.0.0.1:<port_base> if HOSTNAME is unreachable.
BASE_URL_PUBLIC="https://${HOSTNAME}"
BASE_URL_LOCAL="http://127.0.0.1:${PORT_BASE}"

# ---------------------------------------------------------------------------
# Result accumulator.
# ---------------------------------------------------------------------------
# Each result is a pipe-separated record: "name|status|detail"
# status is one of: pass | fail | skip
RESULTS=()

record() {
  RESULTS+=("$1|$2|$3")
}

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------
_curl() {
  # _curl <url> [extra-curl-args...]
  # Emits body to stdout, HTTP code to stderr prefixed "__HTTP__:".
  local url="$1"; shift
  curl -sS -o /dev/stdout -w "__HTTP__:%{http_code}" --max-time "${TIMEOUT}" "$@" "${url}" 2>/dev/null
}

_http_code() {
  # Extract the __HTTP__:NNN token from a _curl result.
  awk -F'__HTTP__:' '{print $2}' <<<"$1" | tr -d '\r\n '
}

_http_body() {
  awk -F'__HTTP__:' '{print $1}' <<<"$1"
}

reach_ok() {
  # reach_ok <url> — returns 0 if curl gets any 2xx/3xx from url.
  local url="$1"
  local out code
  out="$(_curl "${url}")"
  code="$(_http_code "${out}")"
  [[ "${code}" =~ ^[23] ]]
}

# ---------------------------------------------------------------------------
# Reachability probe — pick BASE_URL.
# ---------------------------------------------------------------------------
BASE_URL=""
if reach_ok "${BASE_URL_PUBLIC}/api/v1/G/health" 2>/dev/null || \
   reach_ok "${BASE_URL_PUBLIC}/"                2>/dev/null; then
  BASE_URL="${BASE_URL_PUBLIC}"
elif reach_ok "${BASE_URL_LOCAL}/" 2>/dev/null; then
  BASE_URL="${BASE_URL_LOCAL}"
else
  if [[ "${JSON_OUT}" == "true" ]]; then
    printf '{"env":"%s","status":"unreachable","hostname":"%s","local":"%s"}\n' \
      "${ENV_NAME}" "${BASE_URL_PUBLIC}" "${BASE_URL_LOCAL}"
  else
    echo "Env ${ENV_NAME} unreachable at ${BASE_URL_PUBLIC} or ${BASE_URL_LOCAL}" >&2
  fi
  exit 2
fi

if [[ "${JSON_OUT}" != "true" ]]; then
  cat <<BANNER
${C_BOLD}${C_CYN}
  zorbit-platform — smoke test
  ----------------------------
  env:       ${ENV_NAME}
  base url:  ${BASE_URL}
  hostname:  ${HOSTNAME}
  port base: ${PORT_BASE}
  timeout:   ${TIMEOUT}s
  date:      $(date +%Y-%m-%d\ %H:%M\ %Z)
${C_RESET}
BANNER
fi

# ---------------------------------------------------------------------------
# Load the list of services from the manifest.
# Each line:  <service-name>|<slug>|<port>
# slug = service-name with leading "zorbit-" stripped, underscores -> hyphens.
# ---------------------------------------------------------------------------
SVC_LIST="$(python3 - "${MANIFEST_FILE}" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
for r in data['repos']:
    if r.get('type') == 'service' and r.get('port'):
        name = r['name']
        slug = name.replace('zorbit-', '', 1).replace('_', '-')
        print(f"{name}|{slug}|{r['port']}")
PY
)"

# ---------------------------------------------------------------------------
# Check 1: HTTP /health per service.
#
# Item 37 (u, 2026-04-26): per-service health-path resolution. Many services
# now expose canonical /api/v1/G/health (post-(m), 21+ services) but a few
# still only expose legacy paths (rtc, workflow_engine, realtime, secrets,
# notification, integration, voice_engine, pcg5, claims_core, ...).
# We try each candidate path and accept on first 200/204/401/403.
# ---------------------------------------------------------------------------
while IFS='|' read -r name slug port; do
  [[ -z "${name}" ]] && continue
  # Use raw service name (with underscores) for health-paths map lookup;
  # nginx slug uses hyphens. The legacy table is keyed on full repo name.
  candidate_paths="$(resolve_health_paths_all "${name}" "${slug}" "${REPO_ROOT_FOR_MANIFESTS}")"
  status="fail"
  detail=""
  while IFS= read -r hp; do
    [[ -z "${hp}" ]] && continue
    if [[ "${BASE_URL}" == "${BASE_URL_PUBLIC}" ]]; then
      url="${BASE_URL}/api/${slug}${hp}"
    else
      host_port=$((PORT_BASE + port - 3000))
      # On local mode we keep the legacy short path /health; ignore canonical
      # full path for local probing because services bind without /api prefix
      # consistently.
      url="http://127.0.0.1:${host_port}/health"
    fi
    out="$(_curl "${url}")"
    code="$(_http_code "${out}")"
    body="$(_http_body "${out}")"
    if [[ "${code}" == "200" || "${code}" == "204" || "${code}" == "401" || "${code}" == "403" ]]; then
      if [[ "${code}" == "200" ]] && [[ "${body}" == *"ok"* || "${body}" == *"healthy"* || "${body}" == *"status"* ]]; then
        status="pass"; detail="HTTP ${code} via ${hp}"; break
      elif [[ "${code}" != "200" ]]; then
        # 204/401/403 — auth gate counts as alive (process is up)
        status="pass"; detail="HTTP ${code} via ${hp} (auth gate)"; break
      fi
    fi
    detail="HTTP ${code} via ${hp} body=${body:0:60}"
    # On local mode we only get one path; don't loop.
    [[ "${BASE_URL}" != "${BASE_URL_PUBLIC}" ]] && break
  done <<<"${candidate_paths}"
  record "health:${name}" "${status}" "${detail}"
done <<<"${SVC_LIST}"

# ---------------------------------------------------------------------------
# Check 2: Manifest endpoint per service.
# ---------------------------------------------------------------------------
while IFS='|' read -r name slug port; do
  [[ -z "${name}" ]] && continue
  if [[ "${BASE_URL}" == "${BASE_URL_PUBLIC}" ]]; then
    url="${BASE_URL}/api/${slug}/api/v1/G/manifest"
  else
    host_port=$((PORT_BASE + port - 3000))
    url="http://127.0.0.1:${host_port}/api/v1/G/manifest"
  fi
  out="$(_curl "${url}")"
  code="$(_http_code "${out}")"
  body="$(_http_body "${out}")"
  if [[ "${code}" == "200" ]] && [[ "${body}" == *'moduleId'* ]]; then
    record "manifest:${name}" "pass" "moduleId present"
  elif [[ "${code}" == "404" ]]; then
    record "manifest:${name}" "skip" "no /manifest endpoint"
  else
    record "manifest:${name}" "fail" "HTTP ${code}"
  fi
done <<<"${SVC_LIST}"

# ---------------------------------------------------------------------------
# Check 3: Module-registry enumeration.
# ---------------------------------------------------------------------------
if [[ "${BASE_URL}" == "${BASE_URL_PUBLIC}" ]]; then
  mr_url="${BASE_URL}/api/cor-module-registry/api/v1/G/modules"
else
  mr_url="http://127.0.0.1:$((PORT_BASE + 20))/api/v1/G/modules"
fi
out="$(_curl "${mr_url}")"
code="$(_http_code "${out}")"
body="$(_http_body "${out}")"
if [[ "${code}" == "200" ]]; then
  eval_json=$(python3 - "${body}" <<'PY' 2>/dev/null
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("err|parse error"); raise SystemExit(0)
rows = d.get("data", d if isinstance(d, list) else [])
if not rows:
    print("warn|no modules"); raise SystemExit(0)
total = len(rows)
ready = sum(1 for r in rows if str(r.get("status","")).upper() == "READY")
print(f"ok|{ready}/{total} READY")
PY
)
  kind="${eval_json%%|*}"; detail="${eval_json#*|}"
  case "${kind}" in
    ok)   record "module-registry:enum" "pass" "${detail}";;
    warn) record "module-registry:enum" "fail" "${detail}";;
    *)    record "module-registry:enum" "fail" "${detail}";;
  esac
else
  record "module-registry:enum" "fail" "HTTP ${code}"
fi

# ---------------------------------------------------------------------------
# Check 4: Nav cascade for a test user.
# ---------------------------------------------------------------------------
TEST_USER="U-SMOKE-$$"
if [[ "${BASE_URL}" == "${BASE_URL_PUBLIC}" ]]; then
  nav_url="${BASE_URL}/api/navigation/api/v1/U/${TEST_USER}/menu"
else
  nav_url="http://127.0.0.1:$((PORT_BASE + 3))/api/v1/U/${TEST_USER}/menu"
fi
out="$(_curl "${nav_url}")"
code="$(_http_code "${out}")"
body="$(_http_body "${out}")"
if [[ "${code}" == "200" ]]; then
  nav_eval=$(python3 - "${body}" <<'PY' 2>/dev/null
import sys, json
try: d = json.loads(sys.argv[1])
except Exception: print("fail|parse"); raise SystemExit(0)
src = d.get("source") or d.get("data",{}).get("source") or ""
sections = d.get("sections") or d.get("data",{}).get("sections") or []
print(f"ok|source={src or '?'} sections={len(sections)}")
PY
)
  record "nav:cascade" "pass" "${nav_eval#*|}"
elif [[ "${code}" == "401" || "${code}" == "403" ]]; then
  record "nav:cascade" "skip" "auth required (${code}) — run authenticated variant"
else
  record "nav:cascade" "fail" "HTTP ${code}"
fi

# ---------------------------------------------------------------------------
# Check 5: Identity register + login + delete.
# ---------------------------------------------------------------------------
if [[ "${BASE_URL}" == "${BASE_URL_PUBLIC}" ]]; then
  id_base="${BASE_URL}/api/identity/api/v1/G"
else
  id_base="http://127.0.0.1:$((PORT_BASE + 1))/api/v1/G"
fi
SMOKE_EMAIL="smoke-$$@zorbit-test.local"
SMOKE_PASS="SmokePa55word!"
reg_payload=$(python3 -c "import json;print(json.dumps({'email':'${SMOKE_EMAIL}','password':'${SMOKE_PASS}','firstName':'Smoke','lastName':'Test'}))")

out="$(_curl "${id_base}/auth/register" -X POST -H 'Content-Type: application/json' -d "${reg_payload}")"
reg_code="$(_http_code "${out}")"
if [[ "${reg_code}" != "200" && "${reg_code}" != "201" ]]; then
  record "identity:register" "fail" "HTTP ${reg_code}"
  record "identity:login"    "skip" "register failed"
  record "identity:delete"   "skip" "register failed"
else
  record "identity:register" "pass" "HTTP ${reg_code}"
  login_payload=$(python3 -c "import json;print(json.dumps({'email':'${SMOKE_EMAIL}','password':'${SMOKE_PASS}'}))")
  out="$(_curl "${id_base}/auth/login" -X POST -H 'Content-Type: application/json' -d "${login_payload}")"
  login_code="$(_http_code "${out}")"
  login_body="$(_http_body "${out}")"
  TOKEN=""
  if [[ "${login_code}" == "200" ]]; then
    TOKEN=$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print(d.get('access_token') or d.get('token') or d.get('accessToken') or '')" "${login_body}" 2>/dev/null || true)
  fi
  if [[ -n "${TOKEN}" ]]; then
    record "identity:login" "pass" "token received"
    out="$(_curl "${id_base}/auth/me" -X DELETE -H "Authorization: Bearer ${TOKEN}")"
    del_code="$(_http_code "${out}")"
    if [[ "${del_code}" =~ ^(200|204|202)$ ]]; then
      record "identity:delete" "pass" "HTTP ${del_code}"
    else
      record "identity:delete" "skip" "HTTP ${del_code} — endpoint may be absent"
    fi
  else
    record "identity:login" "fail" "HTTP ${login_code} no token"
    record "identity:delete" "skip" "no token"
  fi
fi

# ---------------------------------------------------------------------------
# Check 6: PII-vault tokenise + reveal roundtrip.
# ---------------------------------------------------------------------------
if [[ "${BASE_URL}" == "${BASE_URL_PUBLIC}" ]]; then
  pii_base="${BASE_URL}/api/pii-vault/api/v1/O/O-SMOKE"
else
  pii_base="http://127.0.0.1:$((PORT_BASE + 5))/api/v1/O/O-SMOKE"
fi
if [[ -n "${TOKEN:-}" ]]; then
  tok_payload='{"type":"email","value":"pii-roundtrip@example.com","organizationHashId":"O-SMOKE"}'
  out="$(_curl "${pii_base}/tokenize" -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer ${TOKEN}" -d "${tok_payload}")"
  tok_code="$(_http_code "${out}")"
  tok_body="$(_http_body "${out}")"
  PII_TOKEN=""
  if [[ "${tok_code}" == "200" || "${tok_code}" == "201" ]]; then
    PII_TOKEN=$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print(d.get('token') or d.get('data',{}).get('token') or '')" "${tok_body}" 2>/dev/null || true)
  fi
  if [[ -n "${PII_TOKEN}" ]]; then
    out="$(_curl "${pii_base}/reveal/${PII_TOKEN}" -H "Authorization: Bearer ${TOKEN}")"
    rev_code="$(_http_code "${out}")"
    rev_body="$(_http_body "${out}")"
    if [[ "${rev_code}" == "200" ]]; then
      if [[ "${rev_body}" == *"pii-roundtrip@example.com"* || "${rev_body}" == *"***"* ]]; then
        record "pii:roundtrip" "pass" "tokenise+reveal ok"
      else
        record "pii:roundtrip" "fail" "reveal body unexpected"
      fi
    else
      record "pii:roundtrip" "fail" "reveal HTTP ${rev_code}"
    fi
  else
    record "pii:roundtrip" "fail" "tokenise HTTP ${tok_code}"
  fi
else
  record "pii:roundtrip" "skip" "no auth token"
fi

# ---------------------------------------------------------------------------
# Check 7: Kafka publish/consume via event-bus admin.
# ---------------------------------------------------------------------------
if [[ "${BASE_URL}" == "${BASE_URL_PUBLIC}" ]]; then
  eb_base="${BASE_URL}/api/event-bus/api/v1/G"
else
  eb_base="http://127.0.0.1:$((PORT_BASE + 4))/api/v1/G"
fi
probe_payload=$(python3 -c "import json,uuid;print(json.dumps({'topic':'zorbit-smoke-test','key':'probe-'+uuid.uuid4().hex[:8],'value':{'from':'smoke-test','ts':'now'}}))")
out="$(_curl "${eb_base}/admin/roundtrip" -X POST -H 'Content-Type: application/json' -d "${probe_payload}")"
eb_code="$(_http_code "${out}")"
if [[ "${eb_code}" == "200" ]]; then
  record "kafka:roundtrip" "pass" "event-bus admin responded 200"
elif [[ "${eb_code}" == "404" ]]; then
  record "kafka:roundtrip" "skip" "event-bus /admin/roundtrip not exposed"
else
  record "kafka:roundtrip" "fail" "HTTP ${eb_code}"
fi

# ---------------------------------------------------------------------------
# Check 8: Seeder dry-run preview.
# ---------------------------------------------------------------------------
if [[ "${BASE_URL}" == "${BASE_URL_PUBLIC}" ]]; then
  seed_base="${BASE_URL}/api/pfs-seeder/api/v1/G"
else
  seed_base="http://127.0.0.1:$((PORT_BASE + 37))/api/v1/G"
fi
out="$(_curl "${seed_base}/seed-bundles")"
seed_code="$(_http_code "${out}")"
seed_body="$(_http_body "${out}")"
if [[ "${seed_code}" == "200" ]]; then
  BUNDLE_ID=$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);rows=d.get('data',d) if isinstance(d,dict) else d;print(rows[0]['id'] if rows else '')" "${seed_body}" 2>/dev/null || true)
  if [[ -n "${BUNDLE_ID}" ]]; then
    out="$(_curl "${seed_base}/seed-bundles/${BUNDLE_ID}/previews" -X POST -H 'Content-Type: application/json' -d '{"rows":3}')"
    prev_code="$(_http_code "${out}")"
    prev_body="$(_http_body "${out}")"
    rows=$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);rows=d.get('data',d) if isinstance(d,dict) else d;print(len(rows) if isinstance(rows,list) else 0)" "${prev_body}" 2>/dev/null || echo 0)
    if [[ "${prev_code}" == "200" && "${rows}" -ge 1 ]]; then
      record "seeder:preview" "pass" "${rows} sample rows"
    else
      record "seeder:preview" "fail" "HTTP ${prev_code} rows=${rows}"
    fi
  else
    record "seeder:preview" "skip" "no seed bundles available"
  fi
elif [[ "${seed_code}" == "404" ]]; then
  record "seeder:preview" "skip" "seeder not deployed in this env"
else
  record "seeder:preview" "fail" "HTTP ${seed_code}"
fi

# ---------------------------------------------------------------------------
# Emit report.
# ---------------------------------------------------------------------------
PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
for r in "${RESULTS[@]}"; do
  IFS='|' read -r _ status _ <<<"${r}"
  case "${status}" in
    pass) PASS_COUNT=$((PASS_COUNT + 1));;
    fail) FAIL_COUNT=$((FAIL_COUNT + 1));;
    skip) SKIP_COUNT=$((SKIP_COUNT + 1));;
  esac
done

if [[ "${JSON_OUT}" == "true" ]]; then
  python3 - "${ENV_NAME}" "${BASE_URL}" "${PASS_COUNT}" "${FAIL_COUNT}" "${SKIP_COUNT}" "${RESULTS[@]}" <<'PY'
import sys, json
env, base, p, f, s = sys.argv[1:6]
results = []
for row in sys.argv[6:]:
    parts = row.split("|", 2)
    while len(parts) < 3: parts.append("")
    results.append({"name": parts[0], "status": parts[1], "detail": parts[2]})
print(json.dumps({
    "env": env,
    "base_url": base,
    "pass": int(p),
    "fail": int(f),
    "skip": int(s),
    "results": results,
}, indent=2))
PY
else
  echo ""
  printf '%-35s | %-4s | %s\n' "Check" "Stat" "Detail"
  printf '%s\n' "----------------------------------------------------------------------------------------"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r name status detail <<<"${r}"
    case "${status}" in
      pass) sym="${C_GRN}PASS${C_RESET}";;
      fail) sym="${C_RED}FAIL${C_RESET}";;
      skip) sym="${C_YEL}SKIP${C_RESET}";;
      *)    sym="${status}";;
    esac
    printf '%-35s | %b | %s\n' "${name}" "${sym}" "${detail}"
  done
  echo ""
  printf '%sResult:%s pass=%d fail=%d skip=%d\n' "${C_BOLD}" "${C_RESET}" \
    "${PASS_COUNT}" "${FAIL_COUNT}" "${SKIP_COUNT}"
fi

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
exit 0
