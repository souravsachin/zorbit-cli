#!/usr/bin/env bash
# =============================================================================
# scripts/install/layer-5-app-stack.sh
#
# Layer 5 — application stack (ze-core / ze-pfs / ze-apps / ze-web).
#
# Delegates to `zorbit env install --env=<env> --preset=<preset>`, which
# resolves the module-list per zorbit-core/platform-spec/install-presets.json
# and produces a lockfile, then to bootstrap-env.sh --module-list <lockfile>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ "$(type -t ui_ok 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck disable=SC1091
[[ "$(type -t state_layer_set 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/state.sh"

layer_5_app_stack() {
  state_layer_set "5_app_stack" "running"

  local env_name="${INSTALL_ENV_NAME:-dev}"
  local preset="${INSTALL_PRESET:-recommended}"
  local vm_ip
  vm_ip="$(jq -r '.layers["2_provision"].data.ip // ""' "$INSTALL_STATE_FILE")"

  if [[ "${INSTALL_DRY_RUN:-0}" = "1" ]]; then
    ui_info "[dry-run] would resolve preset=${preset} for env=${env_name} and deploy via bootstrap-env.sh --module-list <lockfile>"
    state_layer_set "5_app_stack" "done"
    return 0
  fi

  [[ -n "$vm_ip" ]] || ui_die "No VM IP from layer 2"
  local ssh_user="${INSTALL_VM_USER:-admin}"
  local ssh_target="${ssh_user}@${vm_ip}"
  local svc_user="zorbit-${env_name}"

  ui_info "resolving preset=${preset} (env=${env_name})"
  # Resolve preset locally then ship the lockfile, OR run zorbit env install on the VM.
  ssh "$ssh_target" "sudo -u ${svc_user} bash -lc 'cd /opt/zorbit/zorbit-cli && npx -y zorbit env install --env ${env_name} --preset ${preset} --yes'" \
    || { state_layer_set "5_app_stack" "failed"; ui_die "zorbit env install failed"; }

  state_layer_set "5_app_stack" "done"
  ui_ok "app stack deployed"
}
