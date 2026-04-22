#!/usr/bin/env bash
# zorbit-cli/scripts/bootstrap-lib/nginx.sh
# Render the pre-cooked nginx template by substituting two tokens only.
#
# Owner feedback 2026-04-23 (flaw 5):
#   Every env has its own nginx inside its own docker network. Module
#   routes are stable and known in advance. No more per-install dynamic
#   generation — we ship ONE template with all location blocks pre-baked
#   and substitute only:
#       {{HOSTNAME}}    -> full public hostname
#       {{ENV_PREFIX}}  -> ze|zq|zd|zu|zp
#
# Template lives at: zorbit-cli/scripts/templates/nginx-precooked.conf
# Fewer moving parts. Idempotent. Diffable.
# ---------------------------------------------------------------------------

generate_nginx_config() {
  # Arg order preserved for backward compatibility; port_base is now unused
  # (the template references container names, not host-mapped ports).
  local hostname="$1"; local env_name="$2"; local port_base="$3"; local out_file="$4"

  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local template="${lib_dir}/../templates/nginx-precooked.conf"

  if [[ ! -f "${template}" ]]; then
    log_error "nginx template not found at ${template}"
    return 1
  fi

  # Resolve env_prefix from environments.yaml (already in the env spec).
  local env_prefix
  env_prefix=$(yaml_get "${REPO_ROOT_GUESS}/zorbit-core/platform-spec/environments.yaml" \
    "[e['container_prefix'] for e in data['environments'] if e['name']=='${env_name}'][0]" 2>/dev/null || echo "ze")

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY: would render ${template} -> ${out_file}"
    log_info "DRY: substituting {{HOSTNAME}}=${hostname}, {{ENV_PREFIX}}=${env_prefix}"
    return 0
  fi

  # Two-token sed substitution.
  sed -e "s|{{HOSTNAME}}|${hostname}|g" \
      -e "s|{{ENV_PREFIX}}|${env_prefix}|g" \
      "${template}" > "${out_file}"

  log_ok "Rendered nginx config to ${out_file} (hostname=${hostname}, prefix=${env_prefix})"
}

emit_nginx_install_instructions() {
  local config_file="$1"; local hostname="$2"
  cat <<INST

  NGINX install requires sudo. Run the following as root:

      sudo cp ${config_file} /etc/nginx/sites-available/${hostname}
      sudo ln -sf /etc/nginx/sites-available/${hostname} /etc/nginx/sites-enabled/${hostname}
      sudo nginx -t
      sudo systemctl reload nginx

  If no wildcard cert exists for ${hostname}:

      sudo certbot --nginx -d ${hostname}

INST
}
