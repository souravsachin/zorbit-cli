#!/usr/bin/env bash
# =============================================================================
# scripts/adapters/hypervisor/kvm-virt-install.sh
#
# Hypervisor adapter — libvirt/KVM via the `virt-install` CLI.
#
# Same contract as proxmox-cli.sh.
#
# Required env:
#   HYP_KVM_HOST          ssh alias for the libvirt host (default: localhost)
#   HYP_KVM_POOL          libvirt storage pool (default: default)
#   HYP_KVM_NETWORK       libvirt network (default: default)
#   HYP_KVM_CLOUD_IMG     local path to a debian/ubuntu cloud-init qcow2
# =============================================================================

HYP_KVM_HOST="${HYP_KVM_HOST:-localhost}"
HYP_KVM_POOL="${HYP_KVM_POOL:-default}"
HYP_KVM_NETWORK="${HYP_KVM_NETWORK:-default}"
HYP_KVM_CLOUD_IMG="${HYP_KVM_CLOUD_IMG:-/var/lib/libvirt/boot/debian-12-genericcloud-amd64.qcow2}"

_hyp_kvm() {
  if [[ "$HYP_KVM_HOST" = "localhost" ]]; then
    sudo "$@"
  else
    ssh "$HYP_KVM_HOST" "sudo $*"
  fi
}

hyp_check() {
  if [[ "$HYP_KVM_HOST" = "localhost" ]]; then
    command -v virt-install >/dev/null 2>&1 || { echo "  kvm: virt-install not installed" >&2; return 1; }
    sudo -n virsh list --all >/dev/null 2>&1 || { echo "  kvm: NOPASSWD sudo for virsh missing" >&2; return 1; }
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$HYP_KVM_HOST" 'command -v virt-install' >/dev/null 2>&1 \
      || { echo "  kvm: ssh to $HYP_KVM_HOST failed or virt-install missing" >&2; return 1; }
  fi
  return 0
}

hyp_create_vm() {
  local name="$1" vcpu="$2" mem="$3" disk="$4" ip="${5:-}"

  if _hyp_kvm virsh dominfo "$name" >/dev/null 2>&1; then
    echo "  kvm: domain $name already exists — reusing" >&2
    jq -nc --arg name "$name" --arg ip "$ip" '{id: $name, name: $name, ip: $ip, reused: true}'
    return 0
  fi

  echo "  kvm: creating domain $name" >&2
  _hyp_kvm virt-install \
    --name "$name" \
    --memory "$mem" \
    --vcpus "$vcpu" \
    --disk "path=/var/lib/libvirt/images/${name}.qcow2,size=${disk},backing_store=${HYP_KVM_CLOUD_IMG}" \
    --network "network=${HYP_KVM_NETWORK}" \
    --import \
    --osinfo debian12 \
    --noautoconsole >&2

  jq -nc --arg name "$name" --arg ip "${ip:-pending}" '{id: $name, name: $name, ip: $ip, reused: false}'
}

hyp_destroy_vm() {
  local name="$1"
  _hyp_kvm virsh destroy "$name" 2>/dev/null || true
  _hyp_kvm virsh undefine "$name" --remove-all-storage
}

hyp_list_vms() {
  _hyp_kvm virsh list --all --name 2>/dev/null \
    | grep -v '^$' \
    | jq -R -s 'split("\n") | map(select(length>0) | {id: ., name: ., status: "unknown"})'
}

hyp_vm_status() {
  local name="$1"
  local s
  s="$(_hyp_kvm virsh domstate "$name" 2>/dev/null)" || { echo "missing"; return; }
  case "$s" in
    "running") echo "running" ;;
    "shut off"|"shutdown") echo "stopped" ;;
    *) echo "$s" ;;
  esac
}
