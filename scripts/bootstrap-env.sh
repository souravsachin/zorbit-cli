#!/usr/bin/env bash
# =============================================================================
# zorbit-cli/scripts/bootstrap-env.sh
#
# Bootstrap an entire Zorbit environment on a fresh machine.
# MUST be run as the env-specific service account (e.g. zorbit-dev for dev).
#
# Owner feedback 2026-04-23 (flaws 1-5):
#   1. No git-clone + build. Pull pre-built images, or unpack a bundle.
#   2. No caffeinate prompt (macOS-only, not relevant on a server).
#   3. Every y/n prompt documents what "no" does (two-line help block).
#   4. Service account is the env name itself (zorbit-dev for dev, etc.).
#      $USER must equal the env's canonical account name — no fallbacks.
#   5. Nginx config comes from a pre-cooked template with all module
#      locations; the installer only substitutes {{HOSTNAME}} + {{ENV_PREFIX}}.
#
# Exit codes:
#   0   success
#   1   preflight check failed
#   2   user cancelled at confirmation
#   3   service-account guard rejected current user
#   4   deploy step failed
#
# Usage:
#   ./bootstrap-env.sh --env <dev|qa|demo|uat|prod> [--dry-run] [--yes]
#                      [--rollback-last] [--no-auto-rollback]
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/bootstrap-lib"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

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
# shellcheck disable=SC1091
source "${LIB_DIR}/journal.sh"

# ---------------------------------------------------------------------------
# Arg parsing.
# ---------------------------------------------------------------------------
DRY_RUN=false
ENV_ARG=""
SKIP_CONFIRM=false
ROLLBACK_LAST=false
NO_AUTO_ROLLBACK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)           DRY_RUN=true; shift;;
    --env)               ENV_ARG="$2"; shift 2;;
    --yes|-y)            SKIP_CONFIRM=true; shift;;
    --rollback-last)     ROLLBACK_LAST=true; shift;;
    --no-auto-rollback)  NO_AUTO_ROLLBACK=true; shift;;
    --help|-h)
      sed -n '/^#/p' "${BASH_SOURCE[0]}" | sed -n '1,40p'; exit 0;;
    *) log_error "Unknown arg: $1"; exit 2;;
  esac
done
export DRY_RUN
[[ "${NO_AUTO_ROLLBACK}" == "true" ]] && export ZORBIT_SKIP_AUTO_ROLLBACK=true

if [[ -z "${ENV_ARG}" ]]; then
  log_error "--env <dev|qa|demo|uat|prod> is required"
  exit 2
fi

ENV_SHORT="${ENV_ARG#zorbit-}"
ENV_NAME="zorbit-${ENV_SHORT}"
EXPECTED_USER="zorbit-${ENV_SHORT}"

# ---------------------------------------------------------------------------
# Rollback-last mode.
# ---------------------------------------------------------------------------
if [[ "${ROLLBACK_LAST}" == "true" ]]; then
  cat <<ROLLHEAD
${C_BOLD}${C_YEL}
  zorbit-platform — ROLLBACK-LAST
  -------------------------------
  env:    ${ENV_NAME}
  mode:   $( [[ "${DRY_RUN}" == "true" ]] && echo "DRY-RUN" || echo "LIVE" )
  user:   $(whoami)
  journal: $(journal_path "${ENV_NAME}")
  date:   $(date +%Y-%m-%d\ %H:%M\ %Z)
${C_RESET}
ROLLHEAD

  log_step "Planned undos (LIFO)"
  journal_list_undos "${ENV_NAME}" || { log_warn "Nothing to roll back"; exit 0; }

  if [[ "${DRY_RUN}" != "true" && "${SKIP_CONFIRM}" != "true" ]]; then
    ask_yn_with_help CONFIRM_ROLLBACK \
      "Execute the undos above?" \
      "Replay the journal in reverse (LIFO) — containers stopped/removed, networks removed, databases dropped (volumes preserved)." \
      "Exit immediately. Partial install remains in place; you can resume or investigate before retrying." \
      "n"
    [[ "${CONFIRM_ROLLBACK}" != "y" ]] && { log_warn "Cancelled."; exit ${EXIT_USER_CANCEL}; }
  fi

  log_step "Executing undos"
  journal_rollback "${ENV_NAME}"
  RC=$?
  if [[ "${DRY_RUN}" != "true" && ${RC} -eq 0 ]]; then
    journal_archive "${ENV_NAME}"
  fi
  log_ok "Rollback finished (exit ${RC})"
  exit ${RC}
fi

# ---------------------------------------------------------------------------
# Banner.
# ---------------------------------------------------------------------------
cat <<BANNER
${C_BOLD}${C_CYN}
  zorbit-platform — environment bootstrap
  ---------------------------------------
  spec:    zorbit-core/platform-spec/environments.yaml v1.0
  env:     ${ENV_NAME}
  mode:    $( [[ "${DRY_RUN}" == "true" ]] && echo "DRY-RUN (no state changes)" || echo "LIVE" )
  user:    $(whoami)  (expected: ${EXPECTED_USER})
  host:    $(hostname)
  date:    $(date +%Y-%m-%d\ %H:%M\ %Z)
${C_RESET}
BANNER

# ---------------------------------------------------------------------------
# Step 1: Per-env service-account guard.
# Owner feedback 2026-04-23 (flaw 4): $USER MUST match the env account name.
# ---------------------------------------------------------------------------
log_step "Step 1/10 — Per-env service-account guard"

CURRENT_USER="$(whoami)"
if [[ -n "${ZORBIT_SERVICE_USER:-}" && "${CURRENT_USER}" == "${ZORBIT_SERVICE_USER}" ]]; then
  log_warn "ZORBIT_SERVICE_USER override accepted: ${CURRENT_USER}"
elif [[ "${CURRENT_USER}" != "${EXPECTED_USER}" ]]; then
  cat <<GUARD

${C_RED}[BLOCKED]${C_RESET} This script must run as ${EXPECTED_USER} for env ${ENV_NAME}.
Current user: ${CURRENT_USER}

Per-env isolation rule (owner 2026-04-23):
  zorbit-dev    installs into /home/zorbit-dev/
  zorbit-qa     installs into /home/zorbit-qa/
  zorbit-demo   installs into /home/zorbit-demo/
  zorbit-uat    installs into /home/zorbit-uat/
  zorbit-prod   installs into /home/zorbit-prod/

Options:
  1. Switch to the correct account:
        sudo -u ${EXPECTED_USER} bash ${SCRIPT_DIR}/bootstrap-env.sh --env ${ENV_SHORT}

  2. If ${EXPECTED_USER} doesn't exist yet, run the root-prep script first:
        sudo bash ${SCRIPT_DIR}/bootstrap-env-root.sh --env ${ENV_SHORT}

  3. Override (at your own risk; only for repair/forensic work):
        ZORBIT_SERVICE_USER=${CURRENT_USER} ./bootstrap-env.sh --env ${ENV_SHORT}

GUARD
  exit ${EXIT_ACCOUNT_GUARD}
fi
log_ok "Running as correct service account: ${CURRENT_USER}"

# ---------------------------------------------------------------------------
# Step 2: Interactive configuration questions.
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

# Initialise install journal + auto-rollback trap.
journal_init "${ENV_NAME}"
trap 'journal_rollback_auto_trap "${ENV_NAME}" $?' EXIT

# Pull defaults from spec.
DEFAULT_HOST=$(yaml_get "${ENV_FILE}" "[e['default_host'] for e in data['environments'] if e['name']=='${ENV_NAME}'][0]" 2>/dev/null || echo "zorbit-${ENV_SHORT}.onezippy.ai")
PORT_BASE=$(yaml_get "${ENV_FILE}" "[e['port_base'] for e in data['environments'] if e['name']=='${ENV_NAME}'][0]" 2>/dev/null || echo "3100")
INSTALL_DIR=$(yaml_get "${ENV_FILE}" "[e['install_dir'] for e in data['environments'] if e['name']=='${ENV_NAME}'][0]" 2>/dev/null || echo "${HOME}")
CONTAINER_PREFIX=$(yaml_get "${ENV_FILE}" "[e['container_prefix'] for e in data['environments'] if e['name']=='${ENV_NAME}'][0]")

# Q1: hostname (free-form, not y/n).
ask HOSTNAME "Full hostname" "${DEFAULT_HOST}"

# Q2: DNS ready? (y/n with help — flaw 3)
ask_yn_with_help DNS_READY "Public IP or DNS already configured for ${HOSTNAME}?" \
  "Proceed to the nginx step. DNS is assumed to resolve to this server." \
  "Print DNS-setup instructions (A record for ${HOSTNAME} -> this server's IP) and abort (exit 1)." \
  "y"
if [[ "${DNS_READY}" != "y" ]]; then
  cat <<DNS

${C_YEL}[DNS SETUP REQUIRED]${C_RESET}
Add an A record before re-running:
    ${HOSTNAME}   A   <this-server-public-ip>

Then verify:
    dig +short ${HOSTNAME}

Re-run this script once the record resolves.

DNS
  exit ${EXIT_PREFLIGHT_FAIL}
fi

# Q3: Data volume path (free-form).
ask DATA_ROOT "Target disk path for data volumes" "/opt/zorbit-platform/data"

# Q4: Artifact source — replaces the old "Git remote base URL" question
# (flaw 1). Numeric choice, not y/n.
cat <<ARTQ

${C_BOLD}Artifact source${C_RESET} (owner 2026-04-23 flaw 1 — no source clone + build)
  [1] Registry  (recommended)  Pull pre-built images from a container registry.
                               Requires internet + registry auth.
  [2] Bundle                   Unpack a pre-built tarball and docker load the
                               images. For air-gapped installs. Requires a
                               local file path or HTTPS URL.

ARTQ
ARTIFACT_MODE=""
while [[ -z "${ARTIFACT_MODE}" ]]; do
  ask ARTIFACT_CHOICE "Artifact source [1=registry, 2=bundle]" "1"
  case "${ARTIFACT_CHOICE}" in
    1) ARTIFACT_MODE="registry";;
    2) ARTIFACT_MODE="bundle";;
    *) log_warn "Answer 1 or 2.";;
  esac
done

if [[ "${ARTIFACT_MODE}" == "registry" ]]; then
  ask REGISTRY_BASE "Registry base" "ghcr.io/souravsachin"
  ask IMAGE_TAG     "Image tag to pull" "latest"
  export ZORBIT_IMAGE_TAG="${IMAGE_TAG}"
else
  cat <<BND
Bundle location:
  - Local file: /absolute/path/to/zorbit-v<version>-<arch>.tar.gz
  - HTTPS URL : https://zorbit-artifacts.onezippy.ai/bundles/zorbit-v<version>-<arch>.tar.gz
BND
  ask BUNDLE_SRC "Path or URL to bundle tarball" ""
  if [[ -z "${BUNDLE_SRC}" ]]; then
    log_error "Bundle source required for artifact mode 2"
    exit ${EXIT_PREFLIGHT_FAIL}
  fi
fi

# Q5-Q8: Shared TPMs (y/n each, with help — flaw 3).
log_info "Shared TPM instances (non-prod convention uses zs-*):"
ask_yn_with_help TPM_SUPERSET "  Superset shared?" \
  "Point this env's SUPERSET_URL at http://zs-superset:8088 (one instance serves every non-prod env)." \
  "Skip Superset — no BI analytics for this env until a dedicated instance is added later." \
  "y"

ask_yn_with_help TPM_ODOO "    Odoo shared?" \
  "Point this env's ODOO_URL at http://zs-odoo:8069 (shared ERP container for non-prod)." \
  "Skip Odoo — no ERP integration for this env." \
  "y"

ask_yn_with_help TPM_KEYCLOAK "Keycloak shared?" \
  "Point this env's KEYCLOAK_URL at http://zs-keycloak:8080 (shared SSO broker for non-prod)." \
  "Skip Keycloak — fall back to Zorbit's native identity service only (no federated SSO)." \
  "y"

ask_yn_with_help TPM_JITSI "   Jitsi shared?" \
  "Point this env's JITSI_URL at http://zs-jitsi:8443 (shared video-conferencing for non-prod)." \
  "Skip Jitsi — no video-conferencing module in this env." \
  "y"

# NOTE: The "Enable caffeinate" question (flaw 2) was removed. caffeinate is
# macOS laptop-only; servers don't sleep. If a laptop deploy path is ever
# supported, it will live in a separate script.

# ---------------------------------------------------------------------------
# Summary + confirmation.
# ---------------------------------------------------------------------------
cat <<SUMMARY

${C_BOLD}Summary${C_RESET}
  environment    : ${ENV_NAME}
  service acct   : ${CURRENT_USER}
  install dir    : ${INSTALL_DIR}
  hostname       : ${HOSTNAME}
  port base      : ${PORT_BASE}
  container pfx  : ${CONTAINER_PREFIX}
  data root      : ${DATA_ROOT}
  artifact mode  : ${ARTIFACT_MODE}$( [[ "${ARTIFACT_MODE}" == "registry" ]] && echo "  (registry=${REGISTRY_BASE}, tag=${IMAGE_TAG})" || echo "  (bundle=${BUNDLE_SRC})" )
  TPMs (shared)  : superset=${TPM_SUPERSET} odoo=${TPM_ODOO} keycloak=${TPM_KEYCLOAK} jitsi=${TPM_JITSI}
  mode           : $( [[ "${DRY_RUN}" == "true" ]] && echo "DRY-RUN" || echo "LIVE" )

SUMMARY

if [[ "${SKIP_CONFIRM}" != "true" ]]; then
  ask_yn_with_help PROCEED "Confirm summary and proceed?" \
    "Execute the install now (all 10 steps). Failure triggers auto-rollback unless --no-auto-rollback was passed." \
    "Abort immediately with exit code 2. No state changes were made in Steps 3-10 yet." \
    "n"
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
check_python
check_disk_space "${DATA_ROOT}"
check_ports
print_preflight_report

if [[ "${PREFLIGHT_FAIL}" -gt 0 && "${DRY_RUN}" != "true" ]]; then
  log_error "Preflight failed. Fix issues and re-run."
  exit ${EXIT_PREFLIGHT_FAIL}
fi

# ---------------------------------------------------------------------------
# Step 4: Acquire artifacts (registry pull OR bundle load).
# Owner feedback 2026-04-23 (flaw 1): no git clone, no npm build.
# ---------------------------------------------------------------------------
log_step "Step 4/10 — Acquire pre-built artifacts"
if [[ "${ARTIFACT_MODE}" == "registry" ]]; then
  journal_record "${ENV_NAME}" "registry_pull" \
    "docker pull every image in all-repos.yaml (tag=${IMAGE_TAG:-latest})" \
    "# pulled images kept on disk — no automatic removal" "docker,registry"
  pull_all_images "${MANIFEST_FILE}"
else
  journal_record "${ENV_NAME}" "bundle_load" \
    "extract bundle and docker load images (src=${BUNDLE_SRC})" \
    "# loaded images kept on disk — no automatic removal" "docker,bundle"
  load_artifact_bundle "${BUNDLE_SRC}"
fi

# ---------------------------------------------------------------------------
# Step 5: Database init (shared zs-* infra on non-prod).
# ---------------------------------------------------------------------------
log_step "Step 5/10 — Initialise databases (shared zs-* infra)"
journal_record "${ENV_NAME}" "docker_network_create" \
  "docker network create ${CONTAINER_PREFIX}-net" \
  "docker network rm ${CONTAINER_PREFIX}-net || true" "docker,network"
ensure_network "${CONTAINER_PREFIX}-net"
journal_record "${ENV_NAME}" "compose_up_postgres" \
  "start_postgres zs-pg" \
  "docker rm -f zs-pg || true" "docker,postgres"
start_postgres "${ENV_NAME}" "zs-pg" "$((PORT_BASE + 500))" "${DATA_ROOT}"
journal_record "${ENV_NAME}" "compose_up_mongo" \
  "start_mongo zs-mongo" \
  "docker rm -f zs-mongo || true" "docker,mongo"
start_mongo    "zs-mongo" "$((PORT_BASE + 501))" "${DATA_ROOT}"
journal_record "${ENV_NAME}" "compose_up_kafka" \
  "start_kafka zs-kafka" \
  "docker rm -f zs-kafka || true" "docker,kafka"
start_kafka    "zs-kafka" "$((PORT_BASE + 502))"
journal_record "${ENV_NAME}" "compose_up_redis" \
  "start_redis zs-redis" \
  "docker rm -f zs-redis || true" "docker,redis"
start_redis    "zs-redis" "$((PORT_BASE + 503))" "${DATA_ROOT}"
wait_postgres_ready "zs-pg" || log_warn "Postgres not ready — continuing"
journal_record "${ENV_NAME}" "database_create" \
  "create_service_databases zs-pg" \
  "# DBs dropped individually by decommission.sh" "database,postgres"
create_service_databases "zs-pg" "${MANIFEST_FILE}"

# ---------------------------------------------------------------------------
# Step 6: Generate compose file (image-based).
# ---------------------------------------------------------------------------
log_step "Step 6/10 — Generate compose file (image-based, no build: contexts)"
COMPOSE_OUT="${INSTALL_DIR}/compose/docker-compose.${ENV_NAME}.yml"
run_cmd "Ensure ${INSTALL_DIR}/compose exists" mkdir -p "${INSTALL_DIR}/compose"
journal_record "${ENV_NAME}" "compose_generate" \
  "generate_compose_file ${ENV_NAME}" \
  "rm -f ${COMPOSE_OUT}" "compose,yaml"
generate_compose_file "${ENV_NAME}" "${ENV_FILE}" "${MANIFEST_FILE}" "${COMPOSE_OUT}"
log_ok "Compose file: ${COMPOSE_OUT}"
if [[ "${DRY_RUN}" != "true" ]]; then
  log_info "To start services: docker compose -f ${COMPOSE_OUT} up -d"
  log_info "(not auto-started to allow review)"
fi

# ---------------------------------------------------------------------------
# Step 7: Module registry announcement.
# ---------------------------------------------------------------------------
log_step "Step 7/10 — Module registry announcement"
journal_record "${ENV_NAME}" "module_registry_announce" \
  "register_modules_via_kafka ${ENV_NAME}" \
  "# module-registry records are TTL'd — no explicit undo" "kafka,module-registry"
register_modules_via_kafka "${ENV_NAME}" "${MANIFEST_FILE}"
verify_modules_ready "${PORT_BASE}"

# ---------------------------------------------------------------------------
# Step 8: Nginx config (pre-cooked template + sed substitution — flaw 5).
# ---------------------------------------------------------------------------
log_step "Step 8/10 — Nginx config (pre-cooked template, sed substitution)"
NGINX_OUT="${INSTALL_DIR}/config/${HOSTNAME}.nginx.conf"
run_cmd "Ensure ${INSTALL_DIR}/config exists" mkdir -p "${INSTALL_DIR}/config"
journal_record "${ENV_NAME}" "nginx_config_install" \
  "render ${TEMPLATES_DIR}/nginx-precooked.conf -> ${NGINX_OUT}" \
  "rm -f ${NGINX_OUT}" "nginx,template"
generate_nginx_config "${HOSTNAME}" "${ENV_NAME}" "${PORT_BASE}" "${NGINX_OUT}"
emit_nginx_install_instructions "${NGINX_OUT}" "${HOSTNAME}"
journal_record "${ENV_NAME}" "certbot_ssl" \
  "certbot --nginx -d ${HOSTNAME} (sudo manual)" \
  "# SSL certs are shared — never auto-delete" "nginx,certbot"

# ---------------------------------------------------------------------------
# Step 9: Verification.
# ---------------------------------------------------------------------------
log_step "Step 9/10 — Final verification"
journal_record "${ENV_NAME}" "smoke_test_run" \
  "smoke-test.sh --env ${ENV_SHORT}" \
  "" "verify,smoke"
verify_service_health "${ENV_NAME}" "${ENV_FILE}" "${MANIFEST_FILE}"

# ---------------------------------------------------------------------------
# Step 10: Systemd + next steps.
# ---------------------------------------------------------------------------
log_step "Step 10/10 — Systemd + next steps"
journal_record "${ENV_NAME}" "systemd_enable" \
  "systemctl enable ${ENV_NAME}.service (sudo manual — done by bootstrap-env-root.sh)" \
  "# systemctl disable/rm requires sudo — see decommission.sh" "systemd,sudo"

print_next_steps "${ENV_NAME}" "${HOSTNAME}"

# Install finished cleanly — archive the journal.
if [[ "${DRY_RUN}" != "true" ]]; then
  journal_archive "${ENV_NAME}"
fi

trap - EXIT

log_ok "Bootstrap complete for ${ENV_NAME}"
exit ${EXIT_OK}
