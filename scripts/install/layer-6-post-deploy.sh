#!/usr/bin/env bash
# =============================================================================
# scripts/install/layer-6-post-deploy.sh
#
# Layer 6 — post-deploy verification + super-admin seed.
#
# Steps:
#   1. seed super_admins via post-deploy-bootstrap.sh
#   2. probe registry / sidebar / health endpoints (smoke)
#   3. emit handover doc skeleton at $INSTALL_HANDOVER_DOC
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ "$(type -t ui_ok 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck disable=SC1091
[[ "$(type -t state_layer_set 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/state.sh"

layer_6_post_deploy() {
  state_layer_set "6_post_deploy" "running"

  local env_name="${INSTALL_ENV_NAME:-dev}"
  local public_url="${INSTALL_PUBLIC_URL:-https://zorbit-${env_name}.onezippy.ai}"

  if [[ "${INSTALL_DRY_RUN:-0}" = "1" ]]; then
    ui_info "[dry-run] would seed super_admins and probe ${public_url}/api/v1/G/health"
    state_layer_set "6_post_deploy" "done"
    return 0
  fi

  local vm_ip
  vm_ip="$(jq -r '.layers["2_provision"].data.ip // ""' "$INSTALL_STATE_FILE")"
  [[ -n "$vm_ip" ]] || ui_die "No VM IP from layer 2"
  local ssh_user="${INSTALL_VM_USER:-admin}"
  local ssh_target="${ssh_user}@${vm_ip}"
  local svc_user="zorbit-${env_name}"

  ui_info "seeding super_admins (delegating to post-deploy-bootstrap.sh)"
  ssh "$ssh_target" "sudo -u ${svc_user} bash /etc/zorbit/scripts/post-deploy-bootstrap.sh --env ${env_name} --yes" \
    || ui_warn "post-deploy seed reported errors (continuing)"

  ui_info "probing public health endpoint: ${public_url}"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${public_url}/api/v1/G/health" || echo "000")"
  if [[ "$code" = "200" ]]; then
    ui_ok "health probe ok (200)"
    state_layer_data "6_post_deploy" "$(jq -nc --arg c "$code" '{health_status: ($c|tonumber), gate_check: "pass"}')"
  else
    ui_warn "health probe returned ${code} — env up but not yet serving"
    state_layer_data "6_post_deploy" "$(jq -nc --arg c "$code" '{health_status: ($c|tonumber? // 0), gate_check: "fail"}')"
  fi

  state_layer_set "6_post_deploy" "done"
}
