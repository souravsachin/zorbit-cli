#!/usr/bin/env bash
# =============================================================================
# zorbit-cli/scripts/bootstrap-env.sh
#
# Bootstrap an entire Zorbit environment on a fresh machine.
# MUST be run as a Zorbit service account (zorbit-svc or zorbit-deployer).
#
# Exit codes:
#   0   success
#   1   preflight check failed
#   2   user cancelled at confirmation
#   3   service-account guard rejected current user
#   4   deploy step failed
#
# Usage:
#   ./bootstrap-env.sh [--dry-run] [--env <name>] [--yes]
#
#   --dry-run   Print every state-changing command without executing.
#   --env       Skip env prompt (dev|qa|demo|uat|prod).
#   --yes       Skip final confirmation prompt.
#
# Author: Zorbit platform team
# Spec:   zorbit-core/platform-spec/environments.yaml v1.0
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/bootstrap-lib"

# shellcheck disable=SC1091
source "${LIB_DIR}/common.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/preflight.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/databases.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/services.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/nginx.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/verify.sh"

# ---------------------------------------------------------------------------
# Arg parsing.
# ---------------------------------------------------------------------------
DRY_RUN=false
ENV_ARG=""
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift;;
    --env)      ENV_ARG="$2"; shift 2;;
    --yes|-y)   SKIP_CONFIRM=true; shift;;
    --help|-h)
      sed -n '/^#/p' "${BASH_SOURCE[0]}" | sed -n '1,35p'; exit 0;;
    *) log_error "Unknown arg: $1"; exit 2;;
  esac
done
export DRY_RUN

# ---------------------------------------------------------------------------
# Banner.
# ---------------------------------------------------------------------------
cat <<BANNER
${C_BOLD}${C_CYN}
  zorbit-platform — environment bootstrap
  ---------------------------------------
  spec:    zorbit-core/platform-spec/environments.yaml
  mode:    $( [[ "${DRY_RUN}" == "true" ]] && echo "DRY-RUN (no state changes)" || echo "LIVE" )
  user:    $(whoami)
  host:    $(hostname)
  date:    $(date +%Y-%m-%d\ %H:%M\ %Z)
${C_RESET}
BANNER

# ---------------------------------------------------------------------------
# Step 1: Service-account guard.
# ---------------------------------------------------------------------------
log_step "Step 1/10 — Service-account guard"

SVC_PATTERN="^(zorbit-svc|zorbit-deployer)$"
if ! check_service_account "${SVC_PATTERN}"; then
  cat <<GUARD

${C_RED}[BLOCKED]${C_RESET} This script must run as a Zorbit service account.

Options:
  1. If zorbit-deployer already exists:
        sudo -u zorbit-deployer -i
        cd \$HOME && ./bootstrap-env.sh

  2. If zorbit-deployer does NOT exist yet, run the sudo-prep script first:
        sudo bash ${SCRIPT_DIR}/bootstrap-env-root.sh

  3. Override (at your own risk) by setting:
        ZORBIT_SERVICE_USER=\$(whoami) ./bootstrap-env.sh

GUARD
  exit ${EXIT_ACCOUNT_GUARD}
fi
log_ok "Running as service account: $(whoami)"

# ---------------------------------------------------------------------------
# Step 2: Interactive questions.
# ---------------------------------------------------------------------------
log_step "Step 2/10 — Configuration questions"

CORE_SPEC_DIR="${REPO_ROOT_GUESS}/zorbit-core/platform-spec"
ENV_FILE="${CORE_SPEC_DIR}/environments.yaml"
MANIFEST_FILE="${CORE_SPEC_DIR}/all-repos.yaml"

if [[ ! -f "${ENV_FILE}" ]]; then
  log_error "Environment spec missing: ${ENV_FILE}"
  log_error "Clone zorbit-core first, or set REPO_ROOT_GUESS=<path>"
  exit ${EXIT_PREFLIGHT_FAIL}
fi

if [[ -n "${ENV_ARG}" ]]; then
  ENV_SHORT="${ENV_ARG}"
else
  ask ENV_SHORT "Environment name [dev|qa|demo|uat|prod]" "dev"
fi
ENV_NAME="zorbit-${ENV_SHORT}"

# Pull defaults from spec.
DEFAULT_HOST=$(yaml_get "${ENV_FILE}" "[e['default_host'] for e in data['environments'] if e['name']=='${ENV_NAME}'][0]" 2>/dev/null || echo "zorbit-${ENV_SHORT}.onezippy.ai")
PORT_BASE=$(yaml_get "${ENV_FILE}" "[e['port_base'] for e in data['environments'] if e['name']=='${ENV_NAME}'][0]" 2>/dev/null || echo "3100")

ask HOSTNAME "Full hostname" "${DEFAULT_HOST}"
ask_yn DNS_READY "Public IP or DNS already configured for ${HOSTNAME}?" "y"
ask DATA_ROOT "Target disk path for data volumes" "/opt/zorbit-platform/data"
ask REMOTE_BASE "Git remote base URL" "https://github.com/souravsachin"

log_info "Shared TPM instances (non-prod convention):"
ask_yn TPM_SUPERSET "  Superset shared?" "y"
ask_yn TPM_ODOO "    Odoo shared?" "y"
ask_yn TPM_KEYCLOAK "Keycloak shared?" "y"
ask_yn TPM_JITSI "   Jitsi shared?" "y"

ask_yn CAFFEINATE "Enable caffeinate / always-on?" "n"

# ---------------------------------------------------------------------------
# Summary + confirmation.
# ---------------------------------------------------------------------------
cat <<SUMMARY

${C_BOLD}Summary${C_RESET}
  environment : ${ENV_NAME}
  hostname    : ${HOSTNAME}
  port base   : ${PORT_BASE}
  data root   : ${DATA_ROOT}
  git remote  : ${REMOTE_BASE}
  TPMs        : superset=${TPM_SUPERSET} odoo=${TPM_ODOO} keycloak=${TPM_KEYCLOAK} jitsi=${TPM_JITSI}
  caffeinate  : ${CAFFEINATE}
  mode        : $( [[ "${DRY_RUN}" == "true" ]] && echo "DRY-RUN" || echo "LIVE" )

SUMMARY

if [[ "${SKIP_CONFIRM}" != "true" ]]; then
  ask_yn PROCEED "Confirm summary and proceed?" "n"
  if [[ "${PROCEED}" != "y" ]]; then
    log_warn "Cancelled by user."
    exit ${EXIT_USER_CANCEL}
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: Preflight.
# ---------------------------------------------------------------------------
log_step "Step 3/10 — Preflight checks"
check_docker
check_node
check_python
check_git_gh_ssh
check_disk_space "${DATA_ROOT}"
check_ports
print_preflight_report

if [[ "${PREFLIGHT_FAIL}" -gt 0 && "${DRY_RUN}" != "true" ]]; then
  log_error "Preflight failed. Fix issues and re-run."
  exit ${EXIT_PREFLIGHT_FAIL}
fi

# ---------------------------------------------------------------------------
# Step 4: Fetch sources.
# ---------------------------------------------------------------------------
log_step "Step 4/10 — Fetch source repositories"
DEST_ROOT="${HOME}/workspace/zorbit/02_repos"
run_cmd "Ensure dest dir ${DEST_ROOT}" mkdir -p "${DEST_ROOT}"
clone_all_repos "${REMOTE_BASE}" "${MANIFEST_FILE}" "${DEST_ROOT}"

# ---------------------------------------------------------------------------
# Step 5: Build images + service code.
# ---------------------------------------------------------------------------
log_step "Step 5/10 — Build base image + services"
build_base_image
build_service_repos "${MANIFEST_FILE}" "${DEST_ROOT}"

# ---------------------------------------------------------------------------
# Step 6: Database init.
# ---------------------------------------------------------------------------
log_step "Step 6/10 — Initialise databases"
CONTAINER_PREFIX=$(yaml_get "${ENV_FILE}" "[e['container_prefix'] for e in data['environments'] if e['name']=='${ENV_NAME}'][0]")
ensure_network "${CONTAINER_PREFIX}-net"
start_postgres "${ENV_NAME}" "${CONTAINER_PREFIX}-pg" "$((PORT_BASE + 500))" "${DATA_ROOT}"
start_mongo    "${CONTAINER_PREFIX}-mongo" "$((PORT_BASE + 501))" "${DATA_ROOT}"
start_kafka    "${CONTAINER_PREFIX}-kafka" "$((PORT_BASE + 502))"
start_redis    "${CONTAINER_PREFIX}-redis" "$((PORT_BASE + 503))" "${DATA_ROOT}"
wait_postgres_ready "${CONTAINER_PREFIX}-pg" || log_warn "Postgres not ready — continuing"
create_service_databases "${CONTAINER_PREFIX}-pg" "${MANIFEST_FILE}"

# ---------------------------------------------------------------------------
# Step 7: Generate compose + start services.
# ---------------------------------------------------------------------------
log_step "Step 7/10 — Generate compose file + start services"
COMPOSE_OUT="/tmp/docker-compose.${ENV_NAME}.yml"
generate_compose_file "${ENV_NAME}" "${ENV_FILE}" "${MANIFEST_FILE}" "${COMPOSE_OUT}"
log_ok "Compose file: ${COMPOSE_OUT}"
# We do NOT compose-up from the generated file here — each service has its own
# Dockerfile in its repo and the compose template assumes the same layout.
# Kept split so the operator can review ${COMPOSE_OUT} first.
if [[ "${DRY_RUN}" != "true" ]]; then
  log_info "To start services: docker compose -f ${COMPOSE_OUT} up -d"
  log_info "(not auto-started to allow review)"
fi

# ---------------------------------------------------------------------------
# Step 8: Manifest registration.
# ---------------------------------------------------------------------------
log_step "Step 8/10 — Module registry announcement"
register_modules_via_kafka "${ENV_NAME}" "${MANIFEST_FILE}"
verify_modules_ready "${PORT_BASE}"

# ---------------------------------------------------------------------------
# Step 9: Nginx config.
# ---------------------------------------------------------------------------
log_step "Step 9/10 — Nginx site config (sudo required to install)"
NGINX_OUT="/tmp/${HOSTNAME}.nginx.conf"
generate_nginx_config "${HOSTNAME}" "${ENV_NAME}" "${PORT_BASE}" "${NGINX_OUT}"
emit_nginx_install_instructions "${NGINX_OUT}" "${HOSTNAME}"

# ---------------------------------------------------------------------------
# Step 10: Verification + next steps.
# ---------------------------------------------------------------------------
log_step "Step 10/10 — Final verification"
verify_service_health "${ENV_NAME}" "${ENV_FILE}" "${MANIFEST_FILE}"
print_next_steps "${ENV_NAME}" "${HOSTNAME}"

log_ok "Bootstrap complete for ${ENV_NAME}"
exit ${EXIT_OK}
