#!/usr/bin/env bash
# =============================================================================
# provision-zorbit-nonprod-02.sh
#
# One-shot Proxmox provisioning for the Zorbit second non-prod host
# ("zorbit-nonprod-02") that hosts the QA env (zq-* containers).
#
# Adapted from provision-zorbit-nonprod-01.sh per owner directive MSG-088
# (2026-04-27 01:38 +07):
#   - VMID 111, name "zorbit-nonprod-02"
#   - 2 vCPU / 8 GB RAM / 100 GB disk (vs nonprod-01's 8/28/200)
#   - Balloon floor 2048 MB
#   - Single bridge vmbr1 only (no vmbr0 — gw-vm reverse-proxies)
#   - Storage "local" (matches VM 110 actual config — NOT local-lvm)
#   - IP 10.10.10.21 (next after VM 110's 10.10.10.20)
#   - net0 firewall=0 (Proxmox bridge firewall framework dropped traffic with
#     firewall=1 on this VM despite VM 110 working with same flag — likely
#     cluster-firewall rule indexed by VMID. Soldier (cc-3) journal entry.)
#   - nameserver 185.12.64.1/185.12.64.2 (Hetzner DNS — outbound port 53 to
#     1.1.1.1/8.8.8.8 is blocked by Hetzner network policy.)
#
# Naming rationale (owner MSG-088):
#   The VM is hardware = "zorbit-nonprod-02". The QA env runs INSIDE as
#   env-prefixed containers (zq-pg, zq-kafka, zq-mongo, zq-core, zq-pfs,
#   zq-apps, zq-web). "zorbit-qa-01" was rejected as a VM name because
#   "VM = hardware, env = containers".
#
# Runs on pve-hel1 as root (or via sudo from user 's' which has NOPASSWD
# for /usr/sbin/qm, /usr/sbin/pvesm, /usr/sbin/pvesh).
#
# Usage (from laptop):
#   scp /Users/s/workspace/zorbit/02_repos/zorbit-cli/scripts/provision-zorbit-nonprod-02.sh pve:/tmp/
#   ssh pve 'sudo bash /tmp/provision-zorbit-nonprod-02.sh'
#
# Idempotent — safe to re-run; destroys VM 111 first if it exists.
# =============================================================================
set -euo pipefail

VMID=111
VMNAME="zorbit-nonprod-02"
MEMORY_MAX=8192           # 8 GB in MiB
MEMORY_MIN=2048           # balloon floor: 2 GB
CORES=2
DISK_SIZE=100G
PRIVATE_IP=10.10.10.21
PRIVATE_NET=vmbr1
CLOUD_IMG=/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2
STORAGE=local             # dir-type storage (verify with `pvesm status`)
SSH_PUBKEY_PATH=/root/.ssh/authorized_keys

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}==>${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
die()   { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

info "Preflight"
[[ -f "$CLOUD_IMG" ]] || die "Cloud image not found: $CLOUD_IMG"
[[ -f "$SSH_PUBKEY_PATH" ]] || die "SSH pubkey not found: $SSH_PUBKEY_PATH"
command -v qm >/dev/null || die "qm not in PATH"

# Confirm storage exists
if ! pvesm status --content images 2>&1 | grep -q "^${STORAGE}"; then
  warn "Storage '${STORAGE}' not found; available:"
  pvesm status --content images
  die "Edit STORAGE= in this script and re-run"
fi

# Destroy existing VM 111 if present
if qm status "$VMID" >/dev/null 2>&1; then
  warn "VMID $VMID exists — destroying first"
  qm stop "$VMID" 2>/dev/null || true
  sleep 2
  qm destroy "$VMID" --purge 1
  ok "Destroyed old VM $VMID"
fi

info "Creating VM $VMID ($VMNAME) — 2 vCPU / 8 GB RAM / 100 GB disk"
qm create "$VMID" \
  --name "$VMNAME" \
  --memory "$MEMORY_MAX" \
  --balloon "$MEMORY_MIN" \
  --cores "$CORES" \
  --sockets 1 \
  --cpu host \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --net0 "virtio,bridge=${PRIVATE_NET},firewall=0" \
  --agent enabled=1

info "Importing Debian 12 cloud image as disk (storage=${STORAGE}, format=raw)"
qm importdisk "$VMID" "$CLOUD_IMG" "$STORAGE" --format raw

info "Attaching disk + cloud-init drive"
qm set "$VMID" --scsi0 "${STORAGE}:${VMID}/vm-${VMID}-disk-0.raw,discard=on,iothread=1,ssd=1"
qm resize "$VMID" scsi0 "$DISK_SIZE"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0 --bootdisk scsi0

info "Cloud-init config"
qm set "$VMID" --ciuser admin --sshkeys "$SSH_PUBKEY_PATH"
qm set "$VMID" --ipconfig0 "ip=${PRIVATE_IP}/24,gw=10.10.10.1"
# IMPORTANT: Hetzner blocks outbound DNS (port 53) to non-Hetzner resolvers.
# Use Hetzner DNS (185.12.64.1 / 185.12.64.2). Using 1.1.1.1 / 8.8.8.8 will hang
# cloud-init's apt-get update for ~10 min until manual override. See
# 00_docs/platform/zq-env-handover-2026-04-27.md issue #2.
qm set "$VMID" --nameserver "185.12.64.1 185.12.64.2"
qm set "$VMID" --searchdomain onezippy.ai
qm set "$VMID" --onboot 1

# Per-boot post-install: cloud-init user data installs Docker + sets up base
CI_USERDATA=/var/lib/vz/snippets/zorbit-nonprod-02-userdata.yaml
mkdir -p "$(dirname "$CI_USERDATA")"
cat > "$CI_USERDATA" <<'YAML'
#cloud-config
package_update: true
package_upgrade: false
packages:
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - htop
  - net-tools
  - rsync
  - jq
runcmd:
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list'
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - usermod -aG docker admin
  - systemctl enable --now docker
  - mkdir -p /etc/zorbit
  - chown admin:admin /etc/zorbit
YAML

qm set "$VMID" --cicustom "user=local:snippets/$(basename "$CI_USERDATA")"

info "Starting VM"
qm start "$VMID"

info "Waiting for SSH on $PRIVATE_IP (timeout 300s)"
SSH_OK=false
for i in $(seq 1 60); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes admin@"$PRIVATE_IP" 'echo READY' 2>/dev/null | grep -q READY; then
    ok "SSH reachable at admin@${PRIVATE_IP}"
    SSH_OK=true
    break
  fi
  sleep 5
done
[[ "$SSH_OK" == "true" ]] || warn "SSH did not come up within 300s — check qm status $VMID"

info "Waiting for docker (cloud-init runs async, up to 5 min)"
DOCKER_OK=false
for i in $(seq 1 60); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes admin@"$PRIVATE_IP" 'docker info' >/dev/null 2>&1; then
    ok "Docker is running"
    DOCKER_OK=true
    break
  fi
  sleep 5
done
[[ "$DOCKER_OK" == "true" ]] || warn "Docker did not come up within 5 min — cloud-init may still be installing"

echo
ok "VM $VMID ($VMNAME) is up"
echo "  Spec: 2 vCPU / 8 GB RAM (2 GB balloon) / 100 GB disk"
echo "  Private IP: $PRIVATE_IP"
echo "  SSH: ssh admin@${PRIVATE_IP}"
echo "  Bridge: ${PRIVATE_NET} only (no public bridge — gw-vm reverse-proxies)"
echo "  Next: bootstrap zq-* shared infra (zq-pg, zq-kafka, zq-mongo)"
echo "        per zorbit-cli/scripts/bootstrap-env.sh --env qa"
