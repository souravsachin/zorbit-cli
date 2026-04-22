#!/usr/bin/env bash
# =============================================================================
# zorbit-cli/scripts/bootstrap-env-root.sh
#
# Root-only prep for Zorbit. Creates ONE service account PER environment
# passed via --env, for complete per-env isolation.
#
# Owner feedback 2026-04-23 (flaw 4):
#   `zorbit-deployer` was a bad umbrella name. Retire it. We now have one
#   account per environment (zorbit-dev, zorbit-qa, zorbit-demo, zorbit-uat,
#   zorbit-prod). Each account's $HOME is that env's eco-system root; each
#   account can ONLY touch its own env's resources. Docker group membership
#   still required for docker CLI usage.
#
# Usage:
#   sudo bash bootstrap-env-root.sh --env dev
#   sudo bash bootstrap-env-root.sh --env dev,qa,demo        # batch create
#   sudo bash bootstrap-env-root.sh --env dev --dry-run      # review only
#
# After this script completes, switch to the env-specific service account
# and run bootstrap-env.sh:
#
#   sudo -u zorbit-dev bash /path/to/zorbit-cli/scripts/bootstrap-env.sh \
#       --env dev
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=false
ENV_CSV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift;;
    --env)     ENV_CSV="$2"; shift 2;;
    --help|-h)
      sed -n '/^#/p' "${BASH_SOURCE[0]}" | sed -n '1,40p'; exit 0;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done

if [[ -z "${ENV_CSV}" ]]; then
  echo "ERROR: --env <dev|qa|demo|uat|prod> is required (comma-separated for batch)"
  echo "Examples:"
  echo "  sudo bash $0 --env dev"
  echo "  sudo bash $0 --env dev,qa,demo,uat,prod --dry-run"
  exit 2
fi

DATA_ROOT="/opt/zorbit-platform"
LOG_ROOT="/var/log/zorbit-platform"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
do_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '  DRY: %s\n' "$*"
  else
    printf '  $ %s\n' "$*"
    eval "$@"
  fi
}

if [[ "${DRY_RUN}" != "true" && "$(id -u)" -ne 0 ]]; then
  echo "This script requires root. Re-run: sudo bash $0 --env ${ENV_CSV}"
  exit 1
fi

# Parse CSV into array.
IFS=',' read -r -a ENVS <<<"${ENV_CSV}"
for e in "${ENVS[@]}"; do
  case "${e}" in
    dev|qa|demo|uat|prod) ;;
    *) echo "ERROR: invalid env '${e}' (allowed: dev, qa, demo, uat, prod)"; exit 2;;
  esac
done

cat <<BANNER

  ZORBIT PLATFORM - root-only prep (per-env accounts)
  ---------------------------------------------------
  mode:        $( [[ "${DRY_RUN}" == "true" ]] && echo "DRY-RUN" || echo "LIVE" )
  envs:        ${ENV_CSV}
  user:        $(whoami)
  host:        $(hostname)
  data_root:   ${DATA_ROOT}
  log_root:    ${LOG_ROOT}

BANNER

# ---------------------------------------------------------------------------
# 1. System packages (one-time, shared across all envs).
# ---------------------------------------------------------------------------
say "1. Install system packages (shared)"
do_cmd "apt-get update -y"
do_cmd "apt-get install -y \
    ca-certificates curl gnupg lsb-release git \
    python3 python3-pip python3-yaml \
    nginx certbot python3-certbot-nginx \
    logrotate"

# Docker.
if ! command -v docker >/dev/null 2>&1; then
  say "   Install docker (official script)"
  do_cmd "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh"
  do_cmd "sh /tmp/get-docker.sh"
else
  say "   Docker already installed — skipping"
fi

do_cmd "apt-get install -y docker-compose-plugin || true"

# Node 20 (for zorbit-cli itself; images are pre-built so services don't need node on host).
if ! command -v node >/dev/null 2>&1 || ! node --version | grep -q 'v2[0-9]\.'; then
  say "   Install Node 20"
  do_cmd "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
  do_cmd "apt-get install -y nodejs"
else
  say "   Node already installed — skipping"
fi

# GitHub CLI.
if ! command -v gh >/dev/null 2>&1; then
  say "   Install gh CLI"
  do_cmd "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg"
  do_cmd "chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg"
  do_cmd "echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list"
  do_cmd "apt-get update -y && apt-get install -y gh"
fi

# ---------------------------------------------------------------------------
# 2. Shared data/log roots (one-time).
# ---------------------------------------------------------------------------
say "2. Create shared data + log roots"
do_cmd "mkdir -p ${DATA_ROOT}/snapshots ${LOG_ROOT}"
do_cmd "chmod 755 ${DATA_ROOT} ${LOG_ROOT}"

# ---------------------------------------------------------------------------
# 3. Per-environment account + install dir (loop).
# ---------------------------------------------------------------------------
for env_short in "${ENVS[@]}"; do
  env_name="zorbit-${env_short}"
  svc_user="zorbit-${env_short}"
  svc_home="/home/${svc_user}"
  env_data="${DATA_ROOT}/${env_name}"
  env_log_sub="${LOG_ROOT}/${env_name}"

  say "3.${env_short}. Provision ${env_name}"

  # 3a. Service account.
  if id -u "${svc_user}" >/dev/null 2>&1; then
    say "   User ${svc_user} already exists — skipping useradd"
  else
    do_cmd "useradd -r -s /bin/bash -m -d ${svc_home} ${svc_user}"
  fi
  do_cmd "usermod -aG docker ${svc_user}"

  # 3b. Install dir = service account $HOME. The entire env eco-system
  # sits under that directory.
  do_cmd "mkdir -p ${svc_home}/artifacts ${svc_home}/compose ${svc_home}/config"
  do_cmd "chown -R ${svc_user}:${svc_user} ${svc_home}"
  do_cmd "chmod 750 ${svc_home}"

  # 3c. Per-env data + log subdirs owned by the env's account only.
  do_cmd "mkdir -p ${env_data} ${env_log_sub}"
  do_cmd "chown -R ${svc_user}:${svc_user} ${env_data} ${env_log_sub}"
  do_cmd "chmod 750 ${env_data} ${env_log_sub}"

  # 3d. Systemd unit per env.
  systemd_unit="/etc/systemd/system/${env_name}.service"
  UNIT_CONTENT="[Unit]
Description=Zorbit Platform — ${env_name}
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=true
User=${svc_user}
WorkingDirectory=${svc_home}
ExecStart=/bin/bash -lc 'cd ${svc_home}/compose && for c in docker-compose.*.yml; do [ -f \"\$c\" ] && docker compose -f \"\$c\" up -d; done'
ExecStop=/bin/bash -lc 'cd ${svc_home}/compose && for c in docker-compose.*.yml; do [ -f \"\$c\" ] && docker compose -f \"\$c\" down; done'

[Install]
WantedBy=multi-user.target
"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  DRY: write systemd unit to ${systemd_unit}"
  else
    printf '%s' "${UNIT_CONTENT}" > "${systemd_unit}"
    do_cmd "systemctl daemon-reload"
    do_cmd "systemctl enable ${env_name}.service"
  fi

  # 3e. Per-env logrotate.
  logrotate_file="/etc/logrotate.d/${env_name}"
  LR_CONTENT="${env_log_sub}/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ${svc_user} ${svc_user}
    sharedscripts
    postrotate
        systemctl reload ${env_name}.service >/dev/null 2>&1 || true
    endscript
}
"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  DRY: write logrotate config to ${logrotate_file}"
  else
    printf '%s' "${LR_CONTENT}" > "${logrotate_file}"
    do_cmd "chmod 644 ${logrotate_file}"
  fi

  # 3f. JSON receipt (one per env).
  cat <<JSON

  === ${env_name} provisioning summary ===
  {
    "env_name":        "${env_name}",
    "service_account": "${svc_user}",
    "install_dir":     "${svc_home}",
    "data_dir":        "${env_data}",
    "log_dir":         "${env_log_sub}",
    "systemd_unit":    "${systemd_unit}",
    "logrotate_file":  "${logrotate_file}",
    "docker_group":    "added",
    "next_step":       "sudo -u ${svc_user} bash ${SCRIPT_DIR}/bootstrap-env.sh --env ${env_short}"
  }

JSON

done

cat <<NEXT

  Next steps (per env you just provisioned):

$( for e in "${ENVS[@]}"; do
     printf '    sudo -u zorbit-%s bash %s/bootstrap-env.sh --env %s --dry-run   # review\n' "$e" "${SCRIPT_DIR}" "$e"
     printf '    sudo -u zorbit-%s bash %s/bootstrap-env.sh --env %s             # execute\n\n' "$e" "${SCRIPT_DIR}" "$e"
   done )
NEXT

exit 0
