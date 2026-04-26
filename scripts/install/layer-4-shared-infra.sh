#!/usr/bin/env bash
# =============================================================================
# scripts/install/layer-4-shared-infra.sh
#
# Layer 4 — shared infrastructure (Postgres, Kafka, Mongo, Redis).
#
# Delegates to bootstrap-env.sh which already encapsulates the env-prefixed
# zs-* container bring-up. We pass --shared-only when the upstream script
# supports it; otherwise we run the full bootstrap and rely on idempotency.
#
# Vendor-neutral: bootstrap-env.sh runs whatever container engine the VM
# has (docker by default).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ "$(type -t ui_ok 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck disable=SC1091
[[ "$(type -t state_layer_set 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/state.sh"

layer_4_shared_infra() {
  state_layer_set "4_shared_infra" "running"

  local env_name="${INSTALL_ENV_NAME:-dev}"

  if [[ "${INSTALL_DRY_RUN:-0}" = "1" ]]; then
    ui_info "[dry-run] would run bootstrap-env.sh --env ${env_name} --shared-only"
    state_layer_set "4_shared_infra" "done"
    return 0
  fi

  local vm_ip
  vm_ip="$(jq -r '.layers["2_provision"].data.ip // ""' "$INSTALL_STATE_FILE")"
  if [[ -z "$vm_ip" ]]; then
    ui_die "No VM IP from layer 2 — cannot run shared infra"
  fi

  local ssh_user="${INSTALL_VM_USER:-admin}"
  local ssh_target="${ssh_user}@${vm_ip}"

  ui_info "running bootstrap-env.sh --env ${env_name} (shared infra)"
  # Use the env-canonical service account on the VM.
  local svc_user="zorbit-${env_name}"
  ssh "$ssh_target" "sudo -u ${svc_user} bash /etc/zorbit/scripts/bootstrap-env.sh --env ${env_name} --yes" \
    || { state_layer_set "4_shared_infra" "failed"; ui_die "bootstrap-env.sh failed"; }

  state_layer_set "4_shared_infra" "done"
  ui_ok "shared infra up"
}
