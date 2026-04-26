#!/usr/bin/env bash
# =============================================================================
# scripts/install/layer-0-detect.sh
#
# Layer 0 — runtime detection.
#
# Determines whether `zorbit install` is running on:
#   - host        : a developer laptop / workstation (orchestrator surface)
#   - vm          : inside a VM (e.g. just provisioned, running bootstrap)
#   - container   : inside a Docker/Podman container (dev-sandbox case)
#
# Vendor-neutral: this layer never names a specific hypervisor or cloud
# provider — it only inspects the running kernel/cgroup namespace markers,
# which are universal Linux primitives.
#
# Outputs runtime to state file at: .layers["0_detect"].data.runtime
# =============================================================================
set -euo pipefail

# This script is invoked from `zorbit-install`, which has already sourced
# lib/state.sh + lib/ui.sh. When run standalone, source them ourselves.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ "$(type -t ui_ok 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck disable=SC1091
[[ "$(type -t state_layer_set 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/state.sh"

layer_0_detect() {
  state_layer_set "0_detect" "running"

  local runtime="host"
  local kernel
  kernel="$(uname -s)"

  if [[ "$kernel" = "Darwin" ]]; then
    runtime="host"   # macOS laptop — always orchestrator surface
  elif [[ -f /.dockerenv ]] || grep -qE '(docker|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then
    runtime="container"
  elif grep -q '^flags.*hypervisor' /proc/cpuinfo 2>/dev/null; then
    # Linux kernel reports the "hypervisor" CPU flag — this is the
    # vendor-neutral signal that we are running as a guest on some
    # virtualisation platform. We deliberately do NOT pattern-match DMI
    # strings (which would name specific hypervisors) — the orchestrator
    # only needs to know "host vs vm vs container", not which vendor.
    runtime="vm"
  fi

  ui_ok "runtime detected: ${UI_BOLD}${runtime}${UI_NC}"

  local data
  data=$(jq -nc --arg r "$runtime" --arg k "$kernel" --arg h "$(hostname)" \
    '{runtime: $r, kernel: $k, hostname: $h}')
  state_layer_data "0_detect" "$data"
  state_layer_set "0_detect" "done"

  # Export for downstream layers.
  export INSTALL_RUNTIME="$runtime"
}
