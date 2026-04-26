#!/usr/bin/env bash
# =============================================================================
# scripts/adapters/hypervisor/proxmox-cli.sh
#
# Hypervisor adapter — Proxmox VE via the local `qm`/`pvesm`/`pvesh` CLI.
#
# Implements the contract documented in 00_docs/platform/unified-installer.md:
#   hyp_check        — adapter usable here?  (returns 0/1)
#   hyp_create_vm    — create + start + wait for ssh; outputs JSON {id, ip}
#   hyp_destroy_vm   — destroy by VMID or name
#   hyp_list_vms     — outputs JSON array
#   hyp_vm_status    — running|stopped|missing
#
# Connection model:
#   - When run on the PVE host directly: uses local `qm`/etc.
#   - When run elsewhere: ssh to ${HYP_PROXMOX_HOST} (env var) and run there.
#
# Required env (override at command line or in /etc/zorbit/install.env):
#   HYP_PROXMOX_HOST          ssh alias for the Proxmox host (default: pve)
#   HYP_PROXMOX_STORAGE       PVE storage name for the disk (default: local)
#   HYP_PROXMOX_BRIDGE        network bridge (default: vmbr1)
#   HYP_PROXMOX_CLOUD_IMG     path on PVE to debian/ubuntu cloud image
#   HYP_PROXMOX_SSH_PUBKEY    path on PVE to authorized_keys file
# =============================================================================

HYP_PROXMOX_HOST="${HYP_PROXMOX_HOST:-pve}"
HYP_PROXMOX_STORAGE="${HYP_PROXMOX_STORAGE:-local}"
HYP_PROXMOX_BRIDGE="${HYP_PROXMOX_BRIDGE:-vmbr1}"
HYP_PROXMOX_CLOUD_IMG="${HYP_PROXMOX_CLOUD_IMG:-/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2}"
HYP_PROXMOX_SSH_PUBKEY="${HYP_PROXMOX_SSH_PUBKEY:-/root/.ssh/authorized_keys}"
HYP_PROXMOX_GATEWAY="${HYP_PROXMOX_GATEWAY:-10.10.10.1}"
HYP_PROXMOX_NAMESERVERS="${HYP_PROXMOX_NAMESERVERS:-185.12.64.1 185.12.64.2}"
HYP_PROXMOX_SEARCHDOMAIN="${HYP_PROXMOX_SEARCHDOMAIN:-onezippy.ai}"

# Helper — run a command on the PVE host (locally if we are it, else via ssh).
_hyp_pve() {
  if command -v qm >/dev/null 2>&1 && [[ "$(hostname -s)" == *"pve"* ]]; then
    sudo "$@"
  else
    ssh "$HYP_PROXMOX_HOST" "sudo $*"
  fi
}

hyp_check() {
  if command -v qm >/dev/null 2>&1; then
    sudo -n qm list >/dev/null 2>&1 && return 0
    echo "  proxmox-cli: qm present but no NOPASSWD sudo for qm" >&2
    return 1
  fi
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HYP_PROXMOX_HOST" 'command -v qm' >/dev/null 2>&1; then
    echo "  proxmox-cli: ssh to ${HYP_PROXMOX_HOST} failed or qm not in PATH there" >&2
    return 1
  fi
  if ! ssh "$HYP_PROXMOX_HOST" 'sudo -n qm list' >/dev/null 2>&1; then
    echo "  proxmox-cli: NOPASSWD sudo for qm/pvesm/pvesh not configured on ${HYP_PROXMOX_HOST}" >&2
    return 1
  fi
  return 0
}

# Pick a free VMID >= 100.
_hyp_next_vmid() {
  local used
  used="$(_hyp_pve qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n)"
  local id=100
  while echo "$used" | grep -qx "$id"; do
    id=$((id + 1))
  done
  echo "$id"
}

hyp_create_vm() {
  # args: name vcpu memory_mb disk_gb [ip]
  local name="$1" vcpu="$2" mem="$3" disk="$4" ip="${5:-}"
  local id
  id="$(_hyp_next_vmid)"

  # Destroy if same name exists.
  local existing_id
  existing_id="$(_hyp_pve qm list 2>/dev/null | awk -v n="$name" 'NR>1 && $2==n {print $1; exit}')"
  if [[ -n "$existing_id" ]]; then
    echo "  proxmox-cli: VM with name $name exists (vmid $existing_id) — reusing"
    id="$existing_id"
    if _hyp_pve qm status "$id" 2>/dev/null | grep -q running; then
      # Read IP from cloud-init.
      ip="$(_hyp_pve qm config "$id" 2>/dev/null | awk -F'[=,/]' '/^ipconfig0:/ {for(i=1;i<=NF;i++) if($i=="ip") {print $(i+1); exit}}')"
      jq -nc --arg id "$id" --arg ip "$ip" --arg name "$name" \
        '{id: $id, ip: $ip, name: $name, reused: true}'
      return 0
    fi
  fi

  [[ -z "$ip" ]] && { echo "  proxmox-cli: ip required (set INSTALL_VM_IP)" >&2; return 1; }

  echo "  proxmox-cli: creating VM $id ($name) on $HYP_PROXMOX_HOST" >&2

  _hyp_pve qm create "$id" \
    --name "$name" \
    --memory "$mem" \
    --balloon $((mem / 4)) \
    --cores "$vcpu" \
    --sockets 1 \
    --cpu host \
    --ostype l26 \
    --scsihw virtio-scsi-single \
    --net0 "virtio,bridge=${HYP_PROXMOX_BRIDGE},firewall=0" \
    --agent enabled=1 >&2

  _hyp_pve qm importdisk "$id" "$HYP_PROXMOX_CLOUD_IMG" "$HYP_PROXMOX_STORAGE" --format raw >&2
  _hyp_pve qm set "$id" --scsi0 "${HYP_PROXMOX_STORAGE}:${id}/vm-${id}-disk-0.raw,discard=on,iothread=1,ssd=1" >&2
  _hyp_pve qm resize "$id" scsi0 "${disk}G" >&2
  _hyp_pve qm set "$id" --ide2 "${HYP_PROXMOX_STORAGE}:cloudinit" >&2
  _hyp_pve qm set "$id" --boot order=scsi0 --bootdisk scsi0 >&2

  _hyp_pve qm set "$id" --ciuser admin --sshkeys "$HYP_PROXMOX_SSH_PUBKEY" >&2
  _hyp_pve qm set "$id" --ipconfig0 "ip=${ip}/24,gw=${HYP_PROXMOX_GATEWAY}" >&2
  _hyp_pve qm set "$id" --nameserver "$HYP_PROXMOX_NAMESERVERS" >&2
  _hyp_pve qm set "$id" --searchdomain "$HYP_PROXMOX_SEARCHDOMAIN" >&2
  _hyp_pve qm set "$id" --onboot 1 >&2

  _hyp_pve qm start "$id" >&2

  jq -nc --arg id "$id" --arg ip "$ip" --arg name "$name" \
    '{id: $id, ip: $ip, name: $name, reused: false}'
}

hyp_destroy_vm() {
  local id_or_name="$1"
  local id="$id_or_name"
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    id="$(_hyp_pve qm list 2>/dev/null | awk -v n="$id_or_name" 'NR>1 && $2==n {print $1; exit}')"
  fi
  [[ -n "$id" ]] || { echo "  proxmox-cli: VM not found" >&2; return 1; }
  _hyp_pve qm stop "$id" 2>/dev/null || true
  sleep 2
  _hyp_pve qm destroy "$id" --purge 1
}

hyp_list_vms() {
  _hyp_pve qm list 2>/dev/null | awk 'NR>1 {print $1, $2, $3}' \
    | jq -R -s 'split("\n") | map(select(length>0) | split(" ") | {id: .[0], name: .[1], status: .[2]})'
}

hyp_vm_status() {
  local id_or_name="$1"
  local id="$id_or_name"
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    id="$(_hyp_pve qm list 2>/dev/null | awk -v n="$id_or_name" 'NR>1 && $2==n {print $1; exit}')"
  fi
  [[ -z "$id" ]] && { echo "missing"; return; }
  local s
  s="$(_hyp_pve qm status "$id" 2>/dev/null | awk '{print $2}')"
  [[ -n "$s" ]] && echo "$s" || echo "missing"
}
