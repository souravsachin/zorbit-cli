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

  # ---------------------------------------------------------------------
  # D1..D9 defect phases (wired 2026-04-27, soldier oo)
  # Owner directive MSG-107: every env spin-up MUST run these phases.
  # The verify-e2e gate (D9) ABORTS layer-6 if the env isn't truly usable.
  # ---------------------------------------------------------------------
  if [[ -n "${INSTALL_RUN_DEFECT_PHASES:-1}" && "${INSTALL_RUN_DEFECT_PHASES}" != "0" ]]; then
    ui_info "running D1..D9 defect-prevention phases"
    local sa_email="${INSTALL_SUPER_ADMIN_EMAIL:-${SUPER_ADMIN_EMAIL:-}}"
    local sa_pass="${INSTALL_SUPER_ADMIN_PASSWORD:-${SUPER_ADMIN_PASSWORD:-}}"
    local sa_json="${INSTALL_SUPER_ADMINS_JSON:-/etc/zorbit/${env_name}/super_admins.json}"
    local image_tag="${INSTALL_IMAGE_TAG:-${IMAGE_TAG:-}}"
    if [[ -z "$sa_email" || -z "$sa_pass" ]]; then
      ui_warn "INSTALL_SUPER_ADMIN_EMAIL/PASSWORD unset — skipping D9 verify (NOT recommended)"
    else
      ENV_PREFIX="${env_name}" \
      IMAGE_TAG="$image_tag" \
      SUPER_ADMINS_JSON="$sa_json" \
      SUPER_ADMIN_EMAIL="$sa_email" \
      SUPER_ADMIN_PASSWORD="$sa_pass" \
      PUBLIC_URL="$public_url" \
      SSH_TARGET="${ssh_target}" \
      bash "${SCRIPT_DIR}/run-defect-phases.sh" "${env_name}" \
        || { ui_die "D1..D9 defect phases failed — env is NOT usable. See /var/log/zorbit-install/*.json"; }
    fi
  fi

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
