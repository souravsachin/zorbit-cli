#!/usr/bin/env bash
# =============================================================================
# scripts/adapters/cert_provider/letsencrypt-certbot.sh
#
# Cert provider — Let's Encrypt via certbot.
#
# Contract:
#   cert_check                   — adapter usable here?
#   cert_ensure <domain>         — make sure a valid cert exists; returns the path
#   cert_path <domain>           — print the on-disk path of the cert
#
# In Zorbit, wildcards are typically pre-provisioned (per memory rule:
# "wildcard certs exist for *.scalatics/claimzippy/vitazoi. NEVER certbot.").
# This adapter respects that: if the wildcard cert is already at
# /etc/letsencrypt/live/<domain>/fullchain.pem, we report "already_provisioned"
# and never call certbot. Only when explicitly invoked with $CERT_FORCE_NEW=1
# will the adapter attempt a fresh issuance.
# =============================================================================

CERT_FORCE_NEW="${CERT_FORCE_NEW:-0}"
CERT_LE_LIVE_DIR="${CERT_LE_LIVE_DIR:-/etc/letsencrypt/live}"
CERT_EMAIL="${CERT_EMAIL:-platform@onezippy.ai}"

cert_check() {
  command -v certbot >/dev/null 2>&1 || {
    if [[ "$CERT_FORCE_NEW" = "1" ]]; then
      echo "  letsencrypt-certbot: certbot CLI not installed and CERT_FORCE_NEW=1" >&2
      return 1
    fi
  }
  return 0
}

cert_path() {
  local domain="$1"
  echo "${CERT_LE_LIVE_DIR}/${domain}/fullchain.pem"
}

cert_ensure() {
  local domain="$1"
  local path
  path="$(cert_path "$domain")"
  if [[ -f "$path" && "$CERT_FORCE_NEW" != "1" ]]; then
    echo "$path"
    return 0
  fi
  if [[ "$CERT_FORCE_NEW" != "1" ]]; then
    echo "  letsencrypt-certbot: cert for $domain not found at $path; refusing to issue (set CERT_FORCE_NEW=1 to override)" >&2
    return 1
  fi
  certbot certonly --standalone -d "$domain" \
    --email "$CERT_EMAIL" --agree-tos --non-interactive
  echo "$path"
}
