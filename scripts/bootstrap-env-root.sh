#!/usr/bin/env bash
# =============================================================================
# zorbit-cli/scripts/bootstrap-env-root.sh
#
# Root-only prep for Zorbit. Run ONCE per machine as:
#
#     sudo bash bootstrap-env-root.sh
#
# Or, to review without executing:
#
#     sudo bash bootstrap-env-root.sh --dry-run
#
# This script creates:
#   - the zorbit-deployer service account
#   - /opt/zorbit-platform with correct ownership
#   - installs system packages (docker, nginx, certbot, python3-yaml)
#   - systemd service for auto-start on boot
#   - logrotate config for /var/log/zorbit-*
#
# After this script completes, switch to the service account and run
# bootstrap-env.sh:
#
#     sudo -u zorbit-deployer -i
#     cd ~/workspace/zorbit/02_repos/zorbit-cli
#     ./scripts/bootstrap-env.sh
#
# Review the commands below before running with sudo.
# =============================================================================
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

SVC_USER="zorbit-deployer"
SVC_HOME="/home/${SVC_USER}"
DATA_ROOT="/opt/zorbit-platform"
LOG_ROOT="/var/log/zorbit-platform"
SYSTEMD_UNIT="/etc/systemd/system/zorbit-platform.service"
LOGROTATE_FILE="/etc/logrotate.d/zorbit-platform"

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
  echo "This script requires root. Re-run: sudo bash $0"
  exit 1
fi

cat <<BANNER

  ZORBIT PLATFORM - root-only prep script
  ---------------------------------------
  mode:   $( [[ "${DRY_RUN}" == "true" ]] && echo "DRY-RUN" || echo "LIVE (will run all commands)" )
  user:   $(whoami)
  host:   $(hostname)

  Review the commands below before continuing.

BANNER

# ---------------------------------------------------------------------------
# 1. System packages.
# ---------------------------------------------------------------------------
say "1. Install system packages"
do_cmd "apt-get update -y"
do_cmd "apt-get install -y \
    ca-certificates curl gnupg lsb-release git \
    python3 python3-pip python3-yaml \
    nginx certbot python3-certbot-nginx \
    logrotate"

# Docker (official convenience script).
if ! command -v docker >/dev/null 2>&1; then
  say "   Install docker (official script)"
  do_cmd "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh"
  do_cmd "sh /tmp/get-docker.sh"
else
  say "   Docker already installed — skipping"
fi

# Docker Compose plugin (redundant on newer docker releases).
do_cmd "apt-get install -y docker-compose-plugin || true"

# Node 20.
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
  do_cmd "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list"
  do_cmd "apt-get update -y && apt-get install -y gh"
fi

# ---------------------------------------------------------------------------
# 2. Create service account.
# ---------------------------------------------------------------------------
say "2. Create service account ${SVC_USER}"
if id -u "${SVC_USER}" >/dev/null 2>&1; then
  say "   User ${SVC_USER} already exists — skipping useradd"
else
  do_cmd "useradd -r -s /bin/bash -m -d ${SVC_HOME} ${SVC_USER}"
fi
do_cmd "usermod -aG docker ${SVC_USER}"

# ---------------------------------------------------------------------------
# 3. Data + log directories.
# ---------------------------------------------------------------------------
say "3. Create data & log directories"
do_cmd "mkdir -p ${DATA_ROOT}/snapshots ${DATA_ROOT}/data ${LOG_ROOT}"
do_cmd "chown -R ${SVC_USER}:${SVC_USER} ${DATA_ROOT} ${LOG_ROOT}"
do_cmd "chmod 755 ${DATA_ROOT} ${LOG_ROOT}"

# ---------------------------------------------------------------------------
# 4. Systemd unit for auto-start.
# ---------------------------------------------------------------------------
say "4. Install systemd unit ${SYSTEMD_UNIT}"
UNIT_CONTENT="[Unit]
Description=Zorbit Platform Eco-system
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=true
User=${SVC_USER}
WorkingDirectory=${SVC_HOME}
ExecStart=/bin/bash -lc 'cd ${SVC_HOME}/workspace/zorbit/02_repos && for c in \$(find . -maxdepth 2 -name docker-compose.*.yml); do docker compose -f \$c up -d; done'
ExecStop=/bin/bash -lc 'cd ${SVC_HOME}/workspace/zorbit/02_repos && for c in \$(find . -maxdepth 2 -name docker-compose.*.yml); do docker compose -f \$c down; done'

[Install]
WantedBy=multi-user.target
"
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "  DRY: write systemd unit to ${SYSTEMD_UNIT}"
else
  printf '%s' "${UNIT_CONTENT}" > "${SYSTEMD_UNIT}"
  do_cmd "systemctl daemon-reload"
  do_cmd "systemctl enable zorbit-platform.service"
fi

# ---------------------------------------------------------------------------
# 5. Logrotate.
# ---------------------------------------------------------------------------
say "5. Install logrotate ${LOGROTATE_FILE}"
LR_CONTENT="${LOG_ROOT}/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ${SVC_USER} ${SVC_USER}
    sharedscripts
    postrotate
        systemctl reload zorbit-platform.service >/dev/null 2>&1 || true
    endscript
}
"
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "  DRY: write logrotate config to ${LOGROTATE_FILE}"
else
  printf '%s' "${LR_CONTENT}" > "${LOGROTATE_FILE}"
  do_cmd "chmod 644 ${LOGROTATE_FILE}"
fi

# ---------------------------------------------------------------------------
# 6. JSON output block for owner's records.
# ---------------------------------------------------------------------------
cat <<JSON

  === Root-prep summary (machine readable) ===
  {
    "service_user":    "${SVC_USER}",
    "service_home":    "${SVC_HOME}",
    "data_root":       "${DATA_ROOT}",
    "log_root":        "${LOG_ROOT}",
    "systemd_unit":    "${SYSTEMD_UNIT}",
    "logrotate_file":  "${LOGROTATE_FILE}",
    "docker_group":    "added",
    "next_step":       "sudo -u ${SVC_USER} -i  then  ./bootstrap-env.sh"
  }

JSON

cat <<NEXT

  Next steps:
    1. sudo -u ${SVC_USER} -i
    2. Clone zorbit-cli + zorbit-core into ~/workspace/zorbit/02_repos/
    3. Run: ./scripts/bootstrap-env.sh --dry-run        # review plan
    4. Run: ./scripts/bootstrap-env.sh                  # execute

NEXT

exit 0
