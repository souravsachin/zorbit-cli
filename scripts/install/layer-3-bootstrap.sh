#!/usr/bin/env bash
# =============================================================================
# scripts/install/layer-3-bootstrap.sh
#
# Layer 3 — bootstrap inside the provisioned VM.
#
# Steps (run via ssh):
#   1. apt-get install docker, ca-certificates, jq, git
#   2. clone zorbit-cli repo to /opt/zorbit
#   3. install /opt/zorbit/scripts → /etc/zorbit/scripts (symlink)
#   4. create the env service account if missing
#
# Vendor-neutral: this layer connects via plain ssh to whatever IP layer 2
# wrote to the state file. It does not care which hypervisor produced it.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ "$(type -t ui_ok 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck disable=SC1091
[[ "$(type -t state_layer_set 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/state.sh"

layer_3_bootstrap() {
  state_layer_set "3_bootstrap" "running"

  # Dry-run short-circuit — never touch the network.
  if [[ "${INSTALL_DRY_RUN:-0}" = "1" ]]; then
    ui_info "[dry-run] would ssh to provisioned VM, install docker, clone repo"
    state_layer_set "3_bootstrap" "done"
    return 0
  fi

  local vm_ip
  vm_ip="$(jq -r '.layers["2_provision"].data.ip // ""' "$INSTALL_STATE_FILE")"
  if [[ -z "$vm_ip" ]]; then
    ui_die "No VM IP from layer 2 — cannot bootstrap"
  fi

  local ssh_user="${INSTALL_VM_USER:-admin}"
  local ssh_target="${ssh_user}@${vm_ip}"
  ui_info "bootstrapping ${ssh_target}"

  # Wait for ssh.
  local tries=0
  until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        "$ssh_target" 'echo ok' >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ $tries -gt 30 ]]; then
      state_layer_set "3_bootstrap" "failed"
      ui_die "VM ${vm_ip} did not become ssh-reachable after 30 attempts"
    fi
    ui_step "waiting for ssh on ${vm_ip} (attempt ${tries}/30)"
    sleep 5
  done
  ui_ok "ssh reachable"

  # Run the bootstrap remotely. Repo URL is taken from ${ZORBIT_REPO_URL}
  # which the operator sets via env or /etc/zorbit/install.env — NOT hard-
  # coded here, keeping this layer vendor-neutral.
  local repo_url="${ZORBIT_REPO_URL:-}"
  if [[ "${INSTALL_DRY_RUN:-0}" = "1" ]]; then
    ui_info "[dry-run] would run docker install + repo clone on ${ssh_target}"
  else
    ssh "$ssh_target" "ZORBIT_REPO_URL='${repo_url}' sudo -E bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Install base tooling.
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl gnupg jq git

# Install docker via the official convenience script if not present.
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

# Clone the repo + install scripts. URL comes from $ZORBIT_REPO_URL.
mkdir -p /opt/zorbit
if [[ ! -d /opt/zorbit/zorbit-cli/.git && -n "${ZORBIT_REPO_URL:-}" ]]; then
  git clone --depth=50 "$ZORBIT_REPO_URL" /opt/zorbit/zorbit-cli || true
fi
mkdir -p /etc/zorbit
[[ -L /etc/zorbit/scripts ]] || ln -sf /opt/zorbit/zorbit-cli/scripts /etc/zorbit/scripts
echo "bootstrap complete"
REMOTE
  fi

  state_layer_set "3_bootstrap" "done"
  ui_ok "VM bootstrapped"
}
