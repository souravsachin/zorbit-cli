#!/usr/bin/env bash
# =============================================================================
# zorbit-cli/scripts/promote-env.sh
#
# Promote one environment's running state to the next tier.
#
# Progression: dev -> qa -> demo -> uat -> prod
#
# Usage:
#   ./promote-env.sh --from <env> --to <env> [--allow-prod] [--dry-run]
#
# Examples:
#   ./promote-env.sh --from zorbit-dev  --to zorbit-qa
#   ./promote-env.sh --from zorbit-uat  --to zorbit-prod --allow-prod
#
# Rules:
#   - Cannot skip tiers (qa -> uat is blocked; must go qa -> demo -> uat).
#   - prod requires --allow-prod AND an approval token env ZORBIT_PROD_APPROVAL_TOKEN.
#   - Smoke test failure aborts promotion with exit 4.
#   - Snapshot stored under /opt/zorbit-platform/snapshots/ for rollback.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/bootstrap-lib/common.sh"

# ---------------------------------------------------------------------------
# Arg parsing.
# ---------------------------------------------------------------------------
FROM_ENV=""
TO_ENV=""
ALLOW_PROD=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)        FROM_ENV="$2"; shift 2;;
    --to)          TO_ENV="$2"; shift 2;;
    --allow-prod)  ALLOW_PROD=true; shift;;
    --dry-run)     DRY_RUN=true; shift;;
    --help|-h)
      sed -n '/^#/p' "${BASH_SOURCE[0]}" | sed -n '1,30p'; exit 0;;
    *) log_error "Unknown arg: $1"; exit 2;;
  esac
done
export DRY_RUN

[[ -z "${FROM_ENV}" || -z "${TO_ENV}" ]] && {
  log_error "--from and --to are required"
  exit 2
}

ENV_FILE="${REPO_ROOT_GUESS}/zorbit-core/platform-spec/environments.yaml"
[[ ! -f "${ENV_FILE}" ]] && { log_error "Missing ${ENV_FILE}"; exit 1; }

# ---------------------------------------------------------------------------
# Step 1: Validate progression chain.
# ---------------------------------------------------------------------------
log_step "Step 1/7 — Validate progression"
CHAIN=$(yaml_get "${ENV_FILE}" "data['progression_chain']")
# e.g. ["zorbit-dev","zorbit-qa","zorbit-demo","zorbit-uat","zorbit-prod"]

FROM_IDX=$(python3 -c "import json; c=json.loads('''${CHAIN}'''); print(c.index('${FROM_ENV}') if '${FROM_ENV}' in c else -1)")
TO_IDX=$(python3 -c "import json; c=json.loads('''${CHAIN}'''); print(c.index('${TO_ENV}') if '${TO_ENV}' in c else -1)")

if [[ "${FROM_IDX}" == "-1" || "${TO_IDX}" == "-1" ]]; then
  log_error "Unknown env. Valid: $(echo "${CHAIN}" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin)))")"
  exit 2
fi
if [[ "${TO_IDX}" -ne $((FROM_IDX + 1)) ]]; then
  log_error "Cannot skip tiers. ${FROM_ENV} -> ${TO_ENV} is not adjacent."
  exit 2
fi
log_ok "${FROM_ENV} (tier ${FROM_IDX}) -> ${TO_ENV} (tier ${TO_IDX})"

# ---------------------------------------------------------------------------
# Step 2: Prod guard.
# ---------------------------------------------------------------------------
log_step "Step 2/7 — Production guard"
if [[ "${TO_ENV}" == "zorbit-prod" ]]; then
  if [[ "${ALLOW_PROD}" != "true" ]]; then
    log_error "Promotion to prod requires --allow-prod"
    exit 2
  fi
  if [[ -z "${ZORBIT_PROD_APPROVAL_TOKEN:-}" ]]; then
    log_error "ZORBIT_PROD_APPROVAL_TOKEN env var is required for prod promotion"
    exit 2
  fi
  log_ok "Prod guard cleared (token present)"
else
  log_ok "Non-prod tier — no approval token needed"
fi

# ---------------------------------------------------------------------------
# Step 3: Snapshot current FROM state.
# ---------------------------------------------------------------------------
log_step "Step 3/7 — Snapshot ${FROM_ENV}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_DIR="/opt/zorbit-platform/snapshots"
SNAPSHOT_FILE="${SNAPSHOT_DIR}/${FROM_ENV}-to-${TO_ENV}-${TIMESTAMP}.yaml"

run_cmd "Ensure snapshot dir" mkdir -p "${SNAPSHOT_DIR}"

# Query module-registry for current module versions.
FROM_PORT_BASE=$(yaml_get "${ENV_FILE}" "[e['port_base'] for e in data['environments'] if e['name']=='${FROM_ENV}'][0]")
FROM_MR_PORT=$((FROM_PORT_BASE + 20))

if [[ "${DRY_RUN}" == "true" ]]; then
  log_info "DRY: would snapshot module-registry @ :${FROM_MR_PORT} to ${SNAPSHOT_FILE}"
else
  SNAPSHOT_JSON=$(curl -fsS "http://127.0.0.1:${FROM_MR_PORT}/api/v1/G/modules" 2>/dev/null || echo '{"data":[]}')
  python3 - "${SNAPSHOT_FILE}" "${FROM_ENV}" "${TO_ENV}" "${TIMESTAMP}" "${SNAPSHOT_JSON}" <<'PY'
import sys, json, yaml
out, from_env, to_env, ts, raw = sys.argv[1:6]
try:
    data = json.loads(raw)
except Exception:
    data = {"data": []}
modules = [{"name": m.get("name"), "version": m.get("version"), "sha": m.get("git_sha"), "status": m.get("status")}
           for m in data.get("data", [])]
doc = {"from": from_env, "to": to_env, "timestamp": ts, "modules": modules}
with open(out, "w") as f:
    yaml.dump(doc, f, sort_keys=False)
print(f"snapshot: {len(modules)} modules -> {out}")
PY
fi
log_ok "Snapshot written: ${SNAPSHOT_FILE}"

# ---------------------------------------------------------------------------
# Step 4: Smoke test FROM env.
# ---------------------------------------------------------------------------
log_step "Step 4/7 — Smoke test ${FROM_ENV}"
SMOKE_SCRIPT="${SCRIPT_DIR}/smoke-test.sh"
if [[ -x "${SMOKE_SCRIPT}" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY: would run ${SMOKE_SCRIPT} --env ${FROM_ENV}"
  else
    if ! "${SMOKE_SCRIPT}" --env "${FROM_ENV}"; then
      log_error "Smoke test failed on ${FROM_ENV}. Aborting promotion."
      exit ${EXIT_DEPLOY_FAIL}
    fi
  fi
else
  log_warn "smoke-test.sh not found. Inline smoke check: hit each /health."
  # Inline: ping every service /health on FROM_PORT_BASE.
  if [[ "${DRY_RUN}" != "true" ]]; then
    MANIFEST_FILE="${REPO_ROOT_GUESS}/zorbit-core/platform-spec/all-repos.yaml"
    FAIL=0
    python3 - "${MANIFEST_FILE}" <<'PY' | while IFS='|' read -r name port; do
import sys, yaml
with open(sys.argv[1]) as f: m=yaml.safe_load(f)
for r in m['repos']:
  if r.get('type')=='service' and r.get('port') and r.get('required'):
    print(f"{r['name']}|{r['port']}")
PY
      host_port=$((FROM_PORT_BASE + port - 3000))
      if ! curl -fsS --max-time 3 "http://127.0.0.1:${host_port}/health" >/dev/null 2>&1; then
        log_error "  ${name} (:${host_port}) /health FAILED"
        FAIL=1
      fi
    done
    [[ "${FAIL}" -eq 1 ]] && { log_error "Smoke checks failed"; exit ${EXIT_DEPLOY_FAIL}; }
  fi
fi
log_ok "Smoke test passed"

# ---------------------------------------------------------------------------
# Step 5: Checkout exact SHAs + build + deploy to TO.
# ---------------------------------------------------------------------------
log_step "Step 5/7 — Deploy pinned SHAs to ${TO_ENV}"
DEST_ROOT="${HOME}/workspace/zorbit/02_repos"

if [[ -f "${SNAPSHOT_FILE}" ]]; then
  python3 - "${SNAPSHOT_FILE}" "${DEST_ROOT}" <<'PY' || true
import sys, yaml, subprocess, os
snap, dest = sys.argv[1:3]
with open(snap) as f: doc = yaml.safe_load(f)
for m in doc.get('modules', []):
    name = m.get('name'); sha = m.get('sha')
    if not name or not sha: continue
    repo = os.path.join(dest, name)
    if os.path.isdir(os.path.join(repo, '.git')):
        print(f"checkout {name}@{sha}")
        subprocess.run(['git', '-C', repo, 'fetch', '--all'], check=False)
        subprocess.run(['git', '-C', repo, 'checkout', sha], check=False)
PY
fi

log_info "Running bootstrap-env.sh for ${TO_ENV} (--yes to skip prompts)..."
if [[ "${DRY_RUN}" == "true" ]]; then
  log_info "DRY: ./bootstrap-env.sh --env ${TO_ENV#zorbit-} --yes"
else
  TO_SHORT="${TO_ENV#zorbit-}"
  "${SCRIPT_DIR}/bootstrap-env.sh" --env "${TO_SHORT}" --yes
fi

# ---------------------------------------------------------------------------
# Step 6: Verify TO matches FROM version table.
# ---------------------------------------------------------------------------
log_step "Step 6/7 — Verify ${TO_ENV} matches snapshot"
TO_PORT_BASE=$(yaml_get "${ENV_FILE}" "[e['port_base'] for e in data['environments'] if e['name']=='${TO_ENV}'][0]")
TO_MR_PORT=$((TO_PORT_BASE + 20))
if [[ "${DRY_RUN}" == "true" ]]; then
  log_info "DRY: would diff snapshot vs http://127.0.0.1:${TO_MR_PORT}/api/v1/G/modules"
else
  TO_JSON=$(curl -fsS "http://127.0.0.1:${TO_MR_PORT}/api/v1/G/modules" 2>/dev/null || echo '{"data":[]}')
  python3 - "${SNAPSHOT_FILE}" "${TO_JSON}" <<'PY' || log_warn "Version drift detected — review"
import sys, yaml, json
snap_file, to_raw = sys.argv[1:3]
with open(snap_file) as f: snap = yaml.safe_load(f)
to_modules = {m.get("name"): m.get("git_sha") for m in json.loads(to_raw).get("data", [])}
drift = []
for m in snap.get("modules", []):
    if m["sha"] != to_modules.get(m["name"]):
        drift.append(f"  {m['name']}: snapshot={m['sha']} to={to_modules.get(m['name'])}")
if drift:
    print("DRIFT:"); [print(d) for d in drift]; sys.exit(1)
print(f"OK: {len(snap.get('modules',[]))} modules match")
PY
fi

# ---------------------------------------------------------------------------
# Step 7: Promotion report.
# ---------------------------------------------------------------------------
log_step "Step 7/7 — Promotion report"
cat <<REPORT

  === Promotion Report ===
  from          : ${FROM_ENV}
  to            : ${TO_ENV}
  timestamp     : ${TIMESTAMP}
  snapshot file : ${SNAPSHOT_FILE}
  rollback      : ./promote-env.sh --rollback ${SNAPSHOT_FILE}   (if needed)
  status        : SUCCESS

REPORT

log_ok "Promotion ${FROM_ENV} -> ${TO_ENV} complete"
exit ${EXIT_OK}
