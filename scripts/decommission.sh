#!/usr/bin/env bash
# =============================================================================
# zorbit-cli/scripts/decommission.sh
#
# Uninstall a Zorbit environment cleanly. Enumerates all state owned by the
# env (containers, networks, volumes, data dir, nginx site, systemd unit,
# per-service databases), prints a confirmation summary, and removes it.
#
# Usage:
#   ./decommission.sh --env <name> [--yes] [--keep-data] [--dry-run]
#                     [--allow-prod]
#
# Flags:
#   --env <name>    Required. e.g. dev|qa|demo|uat|prod OR full name zorbit-<e>.
#   --yes           Skip interactive "type the env name" confirm.
#   --keep-data     Do NOT drop DBs / remove volumes. Instead pg_dump them to
#                   /opt/zorbit-platform/archive/<env>-<ts>/ for recovery.
#   --dry-run       Print everything that would happen without making changes.
#   --allow-prod    Required (plus env ZORBIT_PROD_DECOMMISSION_TOKEN) when the
#                   env is zorbit-prod. Every other guard still applies.
#
# Exit codes:
#   0   success
#   2   user cancel OR bad invocation
#   3   service-account guard rejected current user
#   4   partial: some steps failed, see report
#   5   env not found (nothing to decommission)
#   6   prod guard blocked
#
# Spec version: 1.0 (2026-04-23)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/bootstrap-lib"

# shellcheck disable=SC1091
source "${LIB_DIR}/common.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/preflight.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/journal.sh"

EXIT_ENV_NOT_FOUND=5
EXIT_PROD_BLOCKED=6

# ---------------------------------------------------------------------------
# Arg parsing.
# ---------------------------------------------------------------------------
ENV_ARG=""
SKIP_CONFIRM=false
KEEP_DATA=false
DRY_RUN=false
ALLOW_PROD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)          ENV_ARG="$2"; shift 2;;
    --yes|-y)       SKIP_CONFIRM=true; shift;;
    --keep-data)    KEEP_DATA=true; shift;;
    --dry-run)      DRY_RUN=true; shift;;
    --allow-prod)   ALLOW_PROD=true; shift;;
    --help|-h)      sed -n '/^#/p' "${BASH_SOURCE[0]}" | sed -n '1,40p'; exit 0;;
    *) log_error "Unknown arg: $1"; exit 2;;
  esac
done
export DRY_RUN

if [[ -z "${ENV_ARG}" ]]; then
  log_error "--env is required"
  exit 2
fi

# Normalise: accept "dev" or "zorbit-dev".
if [[ "${ENV_ARG}" == zorbit-* ]]; then
  ENV_NAME="${ENV_ARG}"
  ENV_SHORT="${ENV_ARG#zorbit-}"
else
  ENV_SHORT="${ENV_ARG}"
  ENV_NAME="zorbit-${ENV_ARG}"
fi

# ---------------------------------------------------------------------------
# Banner.
# ---------------------------------------------------------------------------
cat <<BANNER
${C_BOLD}${C_RED}
  zorbit-platform — DECOMMISSION
  ------------------------------
  env:         ${ENV_NAME}
  keep-data:   ${KEEP_DATA}
  mode:        $( [[ "${DRY_RUN}" == "true" ]] && echo "DRY-RUN (no state changes)" || echo "LIVE" )
  user:        $(whoami)
  host:        $(hostname)
  date:        $(date +%Y-%m-%d\ %H:%M\ %Z)
${C_RESET}
BANNER

# ---------------------------------------------------------------------------
# Step 1: Per-env service-account guard.
# Owner feedback 2026-04-23 (flaw 4): $USER MUST match the env account name.
# ---------------------------------------------------------------------------
log_step "Step 1/8 — Per-env service-account guard"
EXPECTED_USER="zorbit-${ENV_SHORT}"
CURRENT_USER="$(whoami)"
if [[ -n "${ZORBIT_SERVICE_USER:-}" && "${CURRENT_USER}" == "${ZORBIT_SERVICE_USER}" ]]; then
  log_warn "ZORBIT_SERVICE_USER override accepted: ${CURRENT_USER}"
elif [[ "${CURRENT_USER}" != "${EXPECTED_USER}" ]]; then
  cat <<GUARD

${C_RED}[BLOCKED]${C_RESET} decommission.sh must run as ${EXPECTED_USER} for env ${ENV_NAME}.
Current user: ${CURRENT_USER}

Options:
  1. sudo -u ${EXPECTED_USER} bash ${SCRIPT_DIR}/decommission.sh --env ${ENV_SHORT}

  2. Override (at your own risk):
     ZORBIT_SERVICE_USER=\$(whoami) ./decommission.sh --env ${ENV_SHORT}

GUARD
  exit ${EXIT_ACCOUNT_GUARD}
fi
log_ok "Running as correct service account: ${CURRENT_USER}"

# ---------------------------------------------------------------------------
# Step 2: Prod guard.
# ---------------------------------------------------------------------------
log_step "Step 2/8 — Production guard"
if [[ "${ENV_NAME}" == "zorbit-prod" ]]; then
  if [[ "${ALLOW_PROD}" != "true" ]]; then
    log_error "Decommissioning zorbit-prod requires --allow-prod"
    exit ${EXIT_PROD_BLOCKED}
  fi
  if [[ -z "${ZORBIT_PROD_DECOMMISSION_TOKEN:-}" ]]; then
    log_error "ZORBIT_PROD_DECOMMISSION_TOKEN env var is required for prod decommission"
    exit ${EXIT_PROD_BLOCKED}
  fi
  log_warn "PROD decommission authorised (token present). Proceed with extreme care."
else
  log_ok "Non-prod env — no approval token needed"
fi

# ---------------------------------------------------------------------------
# Step 3: Load env spec + resolve container prefix.
# ---------------------------------------------------------------------------
log_step "Step 3/8 — Resolve env metadata"
ENV_FILE="${REPO_ROOT_GUESS}/zorbit-core/platform-spec/environments.yaml"
if [[ ! -f "${ENV_FILE}" ]]; then
  log_error "Environment spec missing: ${ENV_FILE}"
  exit ${EXIT_PREFLIGHT_FAIL}
fi

CONTAINER_PREFIX=$(yaml_get "${ENV_FILE}" "[e['container_prefix'] for e in data['environments'] if e['name']=='${ENV_NAME}'][0]" 2>/dev/null || echo "")
if [[ -z "${CONTAINER_PREFIX}" ]]; then
  log_error "Env ${ENV_NAME} not found in ${ENV_FILE}"
  exit ${EXIT_ENV_NOT_FOUND}
fi
DATA_DIR="/opt/zorbit-platform/${ENV_NAME}"
ARCHIVE_ROOT="/opt/zorbit-platform/archive"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_DIR="${ARCHIVE_ROOT}/${ENV_NAME}-${TIMESTAMP}"
log_ok "container prefix = ${CONTAINER_PREFIX}  data dir = ${DATA_DIR}"

# ---------------------------------------------------------------------------
# Step 4: Discovery phase.
# ---------------------------------------------------------------------------
log_step "Step 4/8 — Discovery"

_docker_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

discover_containers=()
discover_networks=()
discover_volumes=()
discover_databases=()
discover_nginx_sites=()
discover_systemd_units=()

if _docker_ok; then
  # Containers: match prefix ze-|zq-|zd-|zu-|zp- AND (optionally) a zorbit.env label.
  # The prefix query is the primary match; the label check is belt-and-braces.
  while IFS= read -r c; do
    [[ -z "${c}" ]] && continue
    # Never sweep shared infra (zs-*). Also never sweep a prefix that
    # doesn't match the requested env.
    if [[ "${c}" == zs-* ]]; then continue; fi
    if [[ "${c}" == "${CONTAINER_PREFIX}-"* ]]; then
      discover_containers+=("${c}")
    fi
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | sort)

  # Networks.
  while IFS= read -r n; do
    [[ -z "${n}" ]] && continue
    if [[ "${n}" == "${CONTAINER_PREFIX}-net" || "${n}" == zorbit-"${ENV_SHORT}"* ]]; then
      discover_networks+=("${n}")
    fi
  done < <(docker network ls --format '{{.Name}}' 2>/dev/null | sort)

  # Volumes: prefer label match; fall back to name match.
  while IFS= read -r v; do
    [[ -z "${v}" ]] && continue
    discover_volumes+=("${v}")
  done < <(docker volume ls -q --filter "label=zorbit.env=${ENV_NAME}" 2>/dev/null)
  while IFS= read -r v; do
    [[ -z "${v}" ]] && continue
    if [[ "${v}" == "${CONTAINER_PREFIX}-"* ]]; then
      discover_volumes+=("${v}")
    fi
  done < <(docker volume ls -q 2>/dev/null)

  # Dedup volumes.
  if [[ ${#discover_volumes[@]} -gt 0 ]]; then
    mapfile -t discover_volumes < <(printf '%s\n' "${discover_volumes[@]}" | awk 'NF && !seen[$0]++')
  fi
else
  log_warn "Docker not available — skipping container/network/volume discovery"
fi

# Data dir.
if [[ -d "${DATA_DIR}" ]]; then
  DATA_DIR_EXISTS=true
  DATA_DIR_SIZE="$(du -sh "${DATA_DIR}" 2>/dev/null | awk '{print $1}')"
else
  DATA_DIR_EXISTS=false
  DATA_DIR_SIZE="0"
fi

# Nginx sites.
if [[ -d /etc/nginx/sites-enabled ]]; then
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    discover_nginx_sites+=("${f}")
  done < <(find /etc/nginx/sites-enabled -maxdepth 1 -type l \( -name "zorbit-${ENV_SHORT}*" -o -name "${ENV_NAME}*" \) 2>/dev/null | sort)
fi

# Systemd.
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files 2>/dev/null | grep -q "^zorbit-${ENV_SHORT}\.service"; then
    discover_systemd_units+=("zorbit-${ENV_SHORT}.service")
  fi
fi

# Per-service databases in zs-pg.
if _docker_ok && docker ps --format '{{.Names}}' | grep -qx "zs-pg"; then
  while IFS= read -r db; do
    [[ -z "${db}" ]] && continue
    discover_databases+=("${db}")
  done < <(docker exec zs-pg psql -U zorbit -d postgres -tAc \
    "SELECT datname FROM pg_database WHERE datname LIKE 'zorbit_%_${ENV_SHORT}'" 2>/dev/null | awk 'NF')
fi

# ---------------------------------------------------------------------------
# Step 5: Discovery summary + confirmation.
# ---------------------------------------------------------------------------
log_step "Step 5/8 — Discovery summary"

cat <<SUMMARY

${C_BOLD}Will remove:${C_RESET}
  containers      : ${#discover_containers[@]}   $(printf '%s ' "${discover_containers[@]:-}")
  networks        : ${#discover_networks[@]}   $(printf '%s ' "${discover_networks[@]:-}")
  volumes         : ${#discover_volumes[@]}   ($( [[ "${KEEP_DATA}" == "true" ]] && echo "preserved via --keep-data" || echo "WILL BE WIPED" ))
  databases       : ${#discover_databases[@]}  $(printf '%s ' "${discover_databases[@]:-}")
  data dir        : ${DATA_DIR} (${DATA_DIR_SIZE}, exists=${DATA_DIR_EXISTS})
  nginx sites     : ${#discover_nginx_sites[@]}   $(printf '%s ' "${discover_nginx_sites[@]:-}")
  systemd units   : ${#discover_systemd_units[@]}   $(printf '%s ' "${discover_systemd_units[@]:-}")

SUMMARY

TOTAL_ITEMS=$((${#discover_containers[@]} + ${#discover_networks[@]} + ${#discover_volumes[@]} + ${#discover_databases[@]}))
if [[ "${DATA_DIR_EXISTS}" == "true" ]]; then TOTAL_ITEMS=$((TOTAL_ITEMS + 1)); fi
TOTAL_ITEMS=$((TOTAL_ITEMS + ${#discover_nginx_sites[@]} + ${#discover_systemd_units[@]}))

if [[ ${TOTAL_ITEMS} -eq 0 ]]; then
  log_warn "Nothing found for ${ENV_NAME} — env appears already decommissioned."
  exit ${EXIT_ENV_NOT_FOUND}
fi

# Belt-and-braces: for every discovered container, sanity-check label vs env.
if _docker_ok; then
  label_mismatch=0
  for c in "${discover_containers[@]:-}"; do
    [[ -z "${c}" ]] && continue
    lbl="$(docker inspect --format '{{ index .Config.Labels "zorbit.env" }}' "${c}" 2>/dev/null || true)"
    if [[ -n "${lbl}" && "${lbl}" != "${ENV_NAME}" ]]; then
      log_error "  container ${c} has zorbit.env=${lbl} (expected ${ENV_NAME})"
      label_mismatch=$((label_mismatch + 1))
    fi
  done
  if [[ ${label_mismatch} -gt 0 ]]; then
    log_error "Refusing to continue: ${label_mismatch} container label mismatch(es). Fix labels or supply correct --env."
    exit 2
  fi
fi

# Type-the-name confirmation (AWS-style).
if [[ "${DRY_RUN}" != "true" && "${SKIP_CONFIRM}" != "true" ]]; then
  printf '\n%sType the environment name to confirm deletion: %s' "${C_YEL}" "${C_RESET}"
  read -r typed_confirm
  if [[ "${typed_confirm}" != "${ENV_NAME}" ]]; then
    log_warn "Input '${typed_confirm}' != '${ENV_NAME}'. Cancelled."
    exit ${EXIT_USER_CANCEL}
  fi
fi

# ---------------------------------------------------------------------------
# Step 6: Execute removal.
# ---------------------------------------------------------------------------
log_step "Step 6/8 — Remove"
FAILURES=0

# 6a. Compose-down if present.
COMPOSE_FILE="${DATA_DIR}/docker-compose.yml"
if [[ -f "${COMPOSE_FILE}" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY: docker compose -f ${COMPOSE_FILE} down"
  else
    log_info "docker compose down on ${COMPOSE_FILE}"
    docker compose -f "${COMPOSE_FILE}" down 2>&1 | sed 's/^/    /' || FAILURES=$((FAILURES + 1))
  fi
else
  log_info "No compose file at ${COMPOSE_FILE} — skipping compose-down"
fi

# 6b. Database handling.
if [[ ${#discover_databases[@]} -gt 0 ]]; then
  if [[ "${KEEP_DATA}" == "true" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "DRY: would pg_dump ${#discover_databases[@]} DB(s) to ${ARCHIVE_DIR}/"
    else
      mkdir -p "${ARCHIVE_DIR}"
      for db in "${discover_databases[@]}"; do
        log_info "  pg_dump ${db} -> ${ARCHIVE_DIR}/${db}.sql"
        if ! docker exec zs-pg pg_dump -U zorbit -d "${db}" >"${ARCHIVE_DIR}/${db}.sql" 2>/dev/null; then
          log_warn "    pg_dump failed for ${db}"
          FAILURES=$((FAILURES + 1))
        fi
      done
    fi
  else
    for db in "${discover_databases[@]}"; do
      if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "DRY: DROP DATABASE ${db}"
      else
        log_info "  DROP DATABASE ${db}"
        if ! docker exec zs-pg psql -U zorbit -d postgres -c "DROP DATABASE IF EXISTS \"${db}\";" >/dev/null 2>&1; then
          log_warn "    DROP failed for ${db}"
          FAILURES=$((FAILURES + 1))
        fi
      fi
    done
  fi
fi

# 6c. Remove containers not handled by compose.
for c in "${discover_containers[@]:-}"; do
  [[ -z "${c}" ]] && continue
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY: docker rm -f ${c}"
    continue
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx "${c}"; then
    log_info "  docker rm -f ${c}"
    docker rm -f "${c}" >/dev/null 2>&1 || FAILURES=$((FAILURES + 1))
  fi
done

# 6d. Remove networks (skip if still attached to surviving containers).
for n in "${discover_networks[@]:-}"; do
  [[ -z "${n}" ]] && continue
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY: docker network rm ${n}"
    continue
  fi
  if docker network inspect "${n}" >/dev/null 2>&1; then
    log_info "  docker network rm ${n}"
    docker network rm "${n}" >/dev/null 2>&1 || {
      log_warn "    network rm failed (containers may still reference it)"
      FAILURES=$((FAILURES + 1))
    }
  fi
done

# 6e. Volumes.
if [[ "${KEEP_DATA}" != "true" ]]; then
  for v in "${discover_volumes[@]:-}"; do
    [[ -z "${v}" ]] && continue
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "DRY: docker volume rm ${v}"
      continue
    fi
    log_info "  docker volume rm ${v}"
    docker volume rm "${v}" >/dev/null 2>&1 || FAILURES=$((FAILURES + 1))
  done
else
  log_info "Volumes preserved (--keep-data)"
fi

# 6f. Data dir.
if [[ "${DATA_DIR_EXISTS}" == "true" ]]; then
  if [[ "${KEEP_DATA}" == "true" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "DRY: would tar ${DATA_DIR} -> ${ARCHIVE_DIR}/data.tar.gz"
    else
      mkdir -p "${ARCHIVE_DIR}"
      tar -czf "${ARCHIVE_DIR}/data.tar.gz" -C "$(dirname "${DATA_DIR}")" "$(basename "${DATA_DIR}")" 2>/dev/null \
        || FAILURES=$((FAILURES + 1))
      log_ok "Archived data dir to ${ARCHIVE_DIR}/data.tar.gz"
    fi
  else
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "DRY: rm -rf ${DATA_DIR}"
    else
      log_info "  rm -rf ${DATA_DIR}"
      rm -rf "${DATA_DIR}" || FAILURES=$((FAILURES + 1))
    fi
  fi
fi

# 6g. Journal cleanup.
if [[ "${DRY_RUN}" != "true" && "${KEEP_DATA}" != "true" ]]; then
  journal_clear "${ENV_NAME}"
fi

# ---------------------------------------------------------------------------
# Step 7: Sudo-required cleanup instructions.
# ---------------------------------------------------------------------------
log_step "Step 7/8 — Sudo-required cleanup"

if [[ ${#discover_nginx_sites[@]} -gt 0 || ${#discover_systemd_units[@]} -gt 0 ]]; then
  cat <<SUDOINST

  The following items need root. Paste into a sudo shell (NOT run from here):

SUDOINST

  for f in "${discover_nginx_sites[@]:-}"; do
    [[ -z "${f}" ]] && continue
    tgt="$(readlink -f "${f}" 2>/dev/null || echo "${f}")"
    echo "      sudo rm -f ${f}"
    [[ -f "${tgt}" && "${tgt}" != "${f}" ]] && echo "      sudo rm -f ${tgt}"
  done
  if [[ ${#discover_nginx_sites[@]} -gt 0 ]]; then
    echo "      sudo nginx -t && sudo systemctl reload nginx"
    echo ""
  fi

  for u in "${discover_systemd_units[@]:-}"; do
    [[ -z "${u}" ]] && continue
    echo "      sudo systemctl stop ${u} || true"
    echo "      sudo systemctl disable ${u} || true"
    echo "      sudo rm -f /etc/systemd/system/${u}"
  done
  if [[ ${#discover_systemd_units[@]} -gt 0 ]]; then
    echo "      sudo systemctl daemon-reload"
  fi
  echo ""
else
  log_ok "Nothing in /etc needs cleanup."
fi

# ---------------------------------------------------------------------------
# Step 8: Final report.
# ---------------------------------------------------------------------------
log_step "Step 8/8 — Report"

cat <<REPORT

  === Decommission Report ===
  env           : ${ENV_NAME}
  mode          : $( [[ "${DRY_RUN}" == "true" ]] && echo "DRY-RUN" || echo "LIVE" )
  keep-data     : ${KEEP_DATA}
  archive dir   : $( [[ "${KEEP_DATA}" == "true" ]] && echo "${ARCHIVE_DIR}" || echo "(none — data was wiped)" )
  containers    : ${#discover_containers[@]} removed
  networks      : ${#discover_networks[@]} removed
  volumes       : ${#discover_volumes[@]} $( [[ "${KEEP_DATA}" == "true" ]] && echo "preserved" || echo "removed")
  databases     : ${#discover_databases[@]} $( [[ "${KEEP_DATA}" == "true" ]] && echo "dumped + kept" || echo "dropped")
  failures      : ${FAILURES}
  needs sudo    : ${#discover_nginx_sites[@]} nginx + ${#discover_systemd_units[@]} systemd

REPORT

if [[ ${FAILURES} -gt 0 ]]; then
  log_error "${FAILURES} step(s) failed — review logs above"
  exit ${EXIT_DEPLOY_FAIL}
fi

log_ok "Decommission complete for ${ENV_NAME}"
exit ${EXIT_OK}
