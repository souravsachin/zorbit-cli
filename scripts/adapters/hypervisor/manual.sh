#!/usr/bin/env bash
# =============================================================================
# scripts/adapters/hypervisor/manual.sh
#
# Hypervisor adapter — MANUAL.
#
# Last-resort adapter for environments where no automated hypervisor CLI is
# available (e.g. baremetal install, ESXi without govc, a cloud the user does
# not have API access to). The adapter prints what would be done and prompts
# the operator to do it themselves and paste the result.
#
# Use --yes / non-interactive will fail this adapter — manual mode requires
# a human at the keyboard.
# =============================================================================

hyp_check() {
  if [[ "${INSTALL_NON_INTERACTIVE:-0}" = "1" ]]; then
    echo "  manual: requires interactive operator — incompatible with --yes" >&2
    return 1
  fi
  return 0
}

hyp_create_vm() {
  local name="$1" vcpu="$2" mem="$3" disk="$4" ip="${5:-}"
  cat >&2 <<MSG

  ┃ MANUAL HYPERVISOR ADAPTER
  ┃
  ┃ Please provision a VM on your platform of choice with these specs:
  ┃   name:      $name
  ┃   vCPU:      $vcpu
  ┃   memory:    ${mem} MB
  ┃   disk:      ${disk} GB
  ┃   ip:        ${ip:-(your choice)}
  ┃
  ┃ Install Debian 12 cloud image, add your ssh public key to /root/.ssh/authorized_keys.
  ┃ When ready, type the IP below.

MSG
  local entered_ip
  read -r -p "  Enter the VM IP (or 'abort'): " entered_ip
  if [[ "$entered_ip" = "abort" ]]; then
    return 1
  fi
  jq -nc --arg name "$name" --arg ip "$entered_ip" \
    '{id: $name, name: $name, ip: $ip, reused: false, manual: true}'
}

hyp_destroy_vm() {
  echo "  manual: please destroy VM '$1' yourself; this adapter cannot do it." >&2
  return 1
}

hyp_list_vms() { echo "[]"; }
hyp_vm_status() { echo "missing"; }
