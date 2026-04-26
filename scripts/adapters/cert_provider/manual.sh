#!/usr/bin/env bash
# =============================================================================
# scripts/adapters/cert_provider/manual.sh
#
# Cert provider — MANUAL. Operator places certs at the requested path.
# =============================================================================

cert_check() {
  if [[ "${INSTALL_NON_INTERACTIVE:-0}" = "1" ]]; then
    echo "  manual: requires interactive operator" >&2; return 1
  fi
  return 0
}

cert_path() { echo "/etc/zorbit/certs/$1.pem"; }

cert_ensure() {
  local domain="$1"
  local path
  path="$(cert_path "$domain")"
  if [[ -f "$path" ]]; then
    echo "$path"
    return 0
  fi
  cat >&2 <<MSG

  ┃ MANUAL CERT
  ┃ Place a fullchain.pem (cert+chain) at:  $path
  ┃ and a privkey.pem at:                  ${path%.pem}.key
  ┃ Press ENTER when ready.
MSG
  read -r _
  echo "$path"
}
