#!/usr/bin/env bash
# =============================================================================
# scripts/install/layer-2-provision.sh
#
# Layer 2 — VM provisioning via the selected hypervisor adapter.
#
# **Vendor-neutral**: this layer never names a specific hypervisor or cloud
# provider. It calls four documented functions on the adapter:
#
#   hyp_check        — returns 0 if the adapter is usable in this env
#   hyp_create_vm    — creates a VM matching requested spec; outputs JSON
#   hyp_vm_status    — running|stopped|missing
#   hyp_destroy_vm   — for rollback
#
# Adapters live in scripts/adapters/hypervisor/<name>.sh and implement these
# functions. The default is set via INSTALL_ADAPTER_HYPERVISOR (CLI flag
# --hypervisor or the value persisted in install-state.json).
#
# Idempotency: if a VM with the requested name/IP already exists and is
# reachable, we skip creation.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="${SCRIPT_DIR}/../adapters/hypervisor"

# shellcheck disable=SC1091
[[ "$(type -t ui_ok 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck disable=SC1091
[[ "$(type -t state_layer_set 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/state.sh"

layer_2_provision() {
  state_layer_set "2_provision" "running"

  local adapter="${INSTALL_ADAPTER_HYPERVISOR:-}"
  if [[ -z "$adapter" ]]; then
    adapter="$(state_adapter_get hypervisor)"
  fi
  if [[ -z "$adapter" ]]; then
    ui_die "No hypervisor adapter selected. Pass --hypervisor=<name> or set INSTALL_ADAPTER_HYPERVISOR. Available: $(ls "${ADAPTER_DIR}" 2>/dev/null | sed 's/\.sh$//' | tr '\n' ' ')"
  fi

  local adapter_path="${ADAPTER_DIR}/${adapter}.sh"
  [[ -f "$adapter_path" ]] || ui_die "Hypervisor adapter not found: ${adapter_path}"
  ui_info "using hypervisor adapter: ${UI_BOLD}${adapter}${UI_NC}"

  # shellcheck disable=SC1090
  source "$adapter_path"

  # Verify adapter contract.
  for fn in hyp_check hyp_create_vm hyp_vm_status hyp_destroy_vm hyp_list_vms; do
    if ! type -t "$fn" >/dev/null 2>&1; then
      ui_die "Adapter ${adapter} missing required function: ${fn}()"
    fi
  done

  # Pre-flight adapter check. Under --dry-run we skip this — the operator is
  # only asking us to walk the layers, not to actually use the adapter.
  if [[ "${INSTALL_DRY_RUN:-0}" != "1" ]]; then
    if ! hyp_check; then
      ui_die "Hypervisor adapter ${adapter} reports it is not usable here. Fix the underlying issue and re-run."
    fi
    ui_ok "adapter ${adapter} ready"
  else
    ui_info "[dry-run] skipping ${adapter} adapter pre-flight check"
  fi

  # Compute VM spec from env settings.
  local vm_name="${INSTALL_VM_NAME:-zorbit-${INSTALL_ENV_NAME:-dev}-01}"
  local vm_vcpu="${INSTALL_VM_VCPU:-2}"
  local vm_mem="${INSTALL_VM_MEMORY_MB:-8192}"
  local vm_disk="${INSTALL_VM_DISK_GB:-100}"
  local vm_ip="${INSTALL_VM_IP:-}"

  if [[ "${INSTALL_DRY_RUN:-0}" = "1" ]]; then
    ui_info "[dry-run] would call hyp_create_vm name=${vm_name} vcpu=${vm_vcpu} mem=${vm_mem}MB disk=${vm_disk}GB ip=${vm_ip:-auto}"
    state_layer_data "2_provision" "$(jq -nc \
      --arg name "$vm_name" --arg ip "${vm_ip:-DRYRUN}" --arg dr "true" \
      '{vm_name: $name, ip: $ip, dry_run: ($dr=="true")}')"
    state_layer_set "2_provision" "done"
    return 0
  fi

  # Idempotency check.
  local status
  status="$(hyp_vm_status "$vm_name" 2>/dev/null || echo missing)"
  if [[ "$status" = "running" ]]; then
    ui_ok "VM ${vm_name} already running — skipping create"
    state_layer_set "2_provision" "done"
    return 0
  fi

  ui_info "creating VM ${vm_name}"
  local result_json
  result_json="$(hyp_create_vm "$vm_name" "$vm_vcpu" "$vm_mem" "$vm_disk" "$vm_ip")" \
    || { state_layer_set "2_provision" "failed"; ui_die "hyp_create_vm failed"; }

  state_layer_data "2_provision" "$result_json"
  state_layer_set "2_provision" "done"
  ui_ok "VM provisioned: $(echo "$result_json" | jq -r '.ip // "no-ip"')"
}
