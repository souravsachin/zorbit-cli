#!/bin/bash
# ============================================================================
# zorbit-cli/scripts/pm2-catalogue.sh
# ============================================================================
# Builds a single combined PM2-services-by-container table covering ALL
# services across ALL ${ENV_PREFIX}-* containers (core / pfs / apps / ai)
# plus zs-* shared infra. Renders to stdout as a markdown table per
# v3 Section H.0 of test-plan-v3-reorg-proposal.md.
#
# Sources of truth:
#   1. `pm2 jlist` from each ${ENV_PREFIX}-{core,pfs,apps,ai} container
#   2. `module_registry.modules` from zs-pg.zorbit_module_registry (psql)
#   3. nginx config inside ${ENV_PREFIX}-web — for resolving public URI
#   4. /api/<svc>/api/v1/G/health probe via ${PUBLIC_URL}
#
# Usage:
#   bash pm2-catalogue.sh \
#     --env ze \
#     --public-url https://zorbit-dev.onezippy.ai \
#     [--fixture path/to/fixture/]   # synthetic mode for testing without bastion
#     [--out path/to/catalogue.md]   # default: stdout
#
# Exit codes:
#   0 success
#   1 missing required arg
#
# Test fixture mode (--fixture <dir>): the script reads JSON files from
# <dir> instead of running docker/psql/curl. See
# scripts/fixtures/pm2-catalogue/README.md for the file layout.
#
# Owner directive 2026-04-26: morning-prep run uses fixture mode only —
# no bastion access tonight. Live mode is implemented but UNTESTED here.
# ============================================================================
set -euo pipefail

ENV_PREFIX=""
PUBLIC_URL=""
FIXTURE_DIR=""
OUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        ENV_PREFIX="$2"; shift 2 ;;
    --public-url) PUBLIC_URL="$2"; shift 2 ;;
    --fixture)    FIXTURE_DIR="$2"; shift 2 ;;
    --out)        OUT_FILE="$2"; shift 2 ;;
    --help|-h)    sed -n '4,40p' "$0"; exit 0 ;;
    *) echo "ERR: unknown arg $1" >&2; exit 1 ;;
  esac
done

[[ -z "$ENV_PREFIX" ]] && { echo "ERR: --env required (ze|zq|zd|zu|zp)" >&2; exit 1; }
[[ -z "$PUBLIC_URL" && -z "$FIXTURE_DIR" ]] && {
  echo "ERR: either --public-url (live) or --fixture <dir> (test) required" >&2
  exit 1
}

# ---- Helpers ---------------------------------------------------------------

fetch_pm2_jlist() {
  local container="$1"
  if [[ -n "$FIXTURE_DIR" ]]; then
    local path="${FIXTURE_DIR}/pm2-jlist__${container}.json"
    if [[ -f "$path" ]]; then cat "$path"; else echo "[]"; fi
  else
    docker exec "$container" pm2 jlist 2>/dev/null || echo "[]"
  fi
}

fetch_modules_manifest_map() {
  if [[ -n "$FIXTURE_DIR" ]]; then
    local path="${FIXTURE_DIR}/module-registry__modules.json"
    if [[ -f "$path" ]]; then cat "$path"; else echo "[]"; fi
  else
    docker exec zs-pg psql -U zorbit -d zorbit_module_registry -tAc \
      "SELECT json_agg(json_build_object('module_id', module_id, 'status', status::text)) FROM modules;" \
      2>/dev/null || echo "[]"
  fi
}

probe_health() {
  local uri="$1"
  if [[ -n "$FIXTURE_DIR" ]]; then
    local path="${FIXTURE_DIR}/health-probes.json"
    if [[ -f "$path" ]]; then
      python3 -c "
import json
d = json.load(open('$path'))
print(d.get('$uri', 0))
"
    else echo 0; fi
  else
    curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "${PUBLIC_URL}${uri}" 2>/dev/null || echo 0
  fi
}

# Resolve a service name to its public URI prefix.
#   zorbit-cor-identity        → /api/identity/
#   zorbit-pfs-form_builder    → /api/pfs-form_builder/
#   zorbit-app-broker          → /api/app-broker/
#   zorbit-ai-tele_uw          → /api/ai-tele_uw/
service_to_uri() {
  local svc="$1"
  local slug="${svc#zorbit-}"
  case "$slug" in
    cor-*) echo "/api/${slug#cor-}/" ;;
    pfs-*) echo "/api/${slug}/" ;;
    app-*) echo "/api/${slug}/" ;;
    ai-*)  echo "/api/${slug}/" ;;
    *)     echo "/api/${slug}/" ;;
  esac
}

# ---- Build catalogue -------------------------------------------------------

emit() {
  if [[ -n "$OUT_FILE" ]]; then echo "$@" >> "$OUT_FILE"; else echo "$@"; fi
}

[[ -n "$OUT_FILE" ]] && : > "$OUT_FILE"

emit "# PM2 Service Catalogue — ${ENV_PREFIX}"
emit ""
emit "Generated: $(date -Iseconds)"
emit "Source: $([[ -n "$FIXTURE_DIR" ]] && echo "fixture (${FIXTURE_DIR})" || echo "live (${PUBLIC_URL})")"
emit ""
emit "## ${ENV_PREFIX}-* PM2 services"
emit ""
emit "| Service | Container | Module manifest | Uptime | PM2 status | Restarts | Internal port | Public nginx URI | Health |"
emit "|---|---|---|---|---|---:|---:|---|---:|"

declare -A MANIFEST_STATUS
manifest_json=$(fetch_modules_manifest_map)
if [[ -n "$manifest_json" && "$manifest_json" != "[]" && "$manifest_json" != "null" ]]; then
  while IFS=$'\t' read -r mid stat; do
    [[ -n "$mid" ]] && MANIFEST_STATUS["$mid"]="$stat"
  done < <(echo "$manifest_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if isinstance(data, list):
    for m in data:
        print(f\"{m['module_id']}\t{m['status']}\")
" 2>/dev/null || true)
fi

TOTAL=0
ONLINE=0
ERRORED=0
RESTART_LOOP=0

for container in "${ENV_PREFIX}-core" "${ENV_PREFIX}-pfs" "${ENV_PREFIX}-apps" "${ENV_PREFIX}-ai"; do
  jlist=$(fetch_pm2_jlist "$container")
  if [[ -z "$jlist" || "$jlist" == "[]" ]]; then
    emit "| _(no PM2 services found in $container)_ | $container | — | — | — | — | — | — | — |"
    continue
  fi

  while IFS=$'\t' read -r name status restarts uptime port; do
    TOTAL=$((TOTAL+1))
    case "$status" in
      online)             ONLINE=$((ONLINE+1)) ;;
      errored|stopped)    ERRORED=$((ERRORED+1)) ;;
      *)                  RESTART_LOOP=$((RESTART_LOOP+1)) ;;
    esac

    manifest_status="${MANIFEST_STATUS[$name]:-MISSING}"
    uri=$(service_to_uri "$name")
    health=$(probe_health "${uri}api/v1/G/health")
    health_marker="$health"
    [[ "$health" == "200" ]] && health_marker="200 OK"
    [[ "$health" == "502" ]] && health_marker="502 BAD-GW"
    [[ "$health" == "0"   ]] && health_marker="—"

    uptime_str="—"
    if [[ -n "$uptime" && "$uptime" != "0" ]]; then
      uptime_str=$(python3 -c "
ms = int('$uptime')
secs = ms // 1000
if secs < 60: print(f'{secs}s')
elif secs < 3600: print(f'{secs//60}m')
elif secs < 86400: print(f'{secs//3600}h {(secs%3600)//60}m')
else: print(f'{secs//86400}d {(secs%86400)//3600}h')
" 2>/dev/null || echo "?")
    fi

    emit "| $name | $container | $manifest_status | $uptime_str | $status | $restarts | $port | \`$uri\` | $health_marker |"
  done < <(echo "$jlist" | python3 -c "
import json, sys, time
data = json.load(sys.stdin)
if not isinstance(data, list): data = []
for p in data:
    name      = p.get('name', '?')
    pm2_env   = p.get('pm2_env') or {}
    status    = pm2_env.get('status', '?')
    restarts  = pm2_env.get('restart_time', 0)
    pm_uptime = pm2_env.get('pm_uptime', 0)
    now_ms    = int(time.time() * 1000)
    uptime_ms = max(0, now_ms - pm_uptime) if pm_uptime else 0
    env_block = pm2_env.get('env', {}) or {}
    port = pm2_env.get('PORT') or env_block.get('PORT', '?')
    print(f'{name}\t{status}\t{restarts}\t{uptime_ms}\t{port}')
" 2>/dev/null || true)
done

emit ""
emit "**Summary:** total=$TOTAL · online=$ONLINE · errored=$ERRORED · restart-loop=$RESTART_LOOP"
emit ""
emit "## zs-* shared infra"
emit ""
emit "| Container | Status |"
emit "|---|---|"

for c in zs-pg zs-mongo zs-kafka zs-redis zs-nginx; do
  if [[ -n "$FIXTURE_DIR" ]]; then
    state_file="${FIXTURE_DIR}/zs-state__${c}.txt"
    if [[ -f "$state_file" ]]; then
      state=$(cat "$state_file")
    else state="(missing)"; fi
  else
    state=$(docker inspect "$c" --format '{{.State.Status}} ({{.State.Health.Status}})' 2>/dev/null || echo "absent")
  fi
  emit "| $c | $state |"
done

emit ""
emit "## Notes"
emit ""
emit "- restart_count > 50 → Section H.5 fail (per test-plan-v3 §H)"
emit "- Health probed via \`${PUBLIC_URL:-fixture}/api/<svc>/api/v1/G/health\`"
emit "- Manifest status \`MISSING\` = PM2 has the process but module_registry doesn't — registry-drift finding"
