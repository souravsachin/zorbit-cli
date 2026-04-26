#!/usr/bin/env bash
# =============================================================================
# scripts/adapters/cloud_dns/manual.sh
#
# Cloud-DNS adapter — MANUAL.
# Prints what record would be set and prompts the operator to do it.
# =============================================================================

dns_check() {
  if [[ "${INSTALL_NON_INTERACTIVE:-0}" = "1" ]]; then
    echo "  manual: requires interactive operator" >&2; return 1
  fi
  return 0
}

dns_upsert() {
  local name="$1" type="$2" value="$3" ttl="${4:-300}"
  cat >&2 <<MSG

  ┃ MANUAL DNS UPSERT
  ┃   record:  $name
  ┃   type:    $type
  ┃   value:   $value
  ┃   ttl:     $ttl
  ┃ Set this record at your DNS provider, then press ENTER.

MSG
  read -r _
}

dns_delete() {
  echo "  manual: please delete record $1 ($2) yourself" >&2
}

dns_get() { echo "null"; }
