#!/usr/bin/env bash
# =============================================================================
# scripts/adapters/cloud_dns/cloudflare-api.sh
#
# Cloud-DNS adapter — Cloudflare via REST API.
#
# Required env:
#   DNS_CF_API_TOKEN   Cloudflare API token with DNS:Edit on target zone
#   DNS_CF_ZONE_ID     Cloudflare zone id
# =============================================================================

DNS_CF_API_TOKEN="${DNS_CF_API_TOKEN:-}"
DNS_CF_ZONE_ID="${DNS_CF_ZONE_ID:-}"
DNS_CF_BASE="https://api.cloudflare.com/client/v4"

dns_check() {
  command -v curl >/dev/null 2>&1 || { echo "  cloudflare-api: curl missing" >&2; return 1; }
  [[ -n "$DNS_CF_API_TOKEN" && -n "$DNS_CF_ZONE_ID" ]] \
    || { echo "  cloudflare-api: DNS_CF_API_TOKEN or DNS_CF_ZONE_ID not set" >&2; return 1; }
  curl -sS -H "Authorization: Bearer $DNS_CF_API_TOKEN" \
    "${DNS_CF_BASE}/zones/${DNS_CF_ZONE_ID}" | jq -e '.success' >/dev/null \
    || { echo "  cloudflare-api: token rejected by Cloudflare" >&2; return 1; }
  return 0
}

_cf_record_id() {
  local name="$1" type="$2"
  curl -sS -H "Authorization: Bearer $DNS_CF_API_TOKEN" \
    "${DNS_CF_BASE}/zones/${DNS_CF_ZONE_ID}/dns_records?name=${name}&type=${type}" \
    | jq -r '.result[0].id // ""'
}

dns_upsert() {
  local name="$1" type="$2" value="$3" ttl="${4:-300}"
  local rid
  rid="$(_cf_record_id "$name" "$type")"
  local payload
  payload=$(jq -nc --arg n "$name" --arg t "$type" --arg v "$value" --argjson ttl "$ttl" \
    '{type:$t, name:$n, content:$v, ttl:$ttl}')
  if [[ -n "$rid" ]]; then
    curl -sS -X PUT -H "Authorization: Bearer $DNS_CF_API_TOKEN" -H 'Content-Type: application/json' \
      "${DNS_CF_BASE}/zones/${DNS_CF_ZONE_ID}/dns_records/${rid}" -d "$payload" >/dev/null
  else
    curl -sS -X POST -H "Authorization: Bearer $DNS_CF_API_TOKEN" -H 'Content-Type: application/json' \
      "${DNS_CF_BASE}/zones/${DNS_CF_ZONE_ID}/dns_records" -d "$payload" >/dev/null
  fi
}

dns_delete() {
  local name="$1" type="$2"
  local rid
  rid="$(_cf_record_id "$name" "$type")"
  [[ -z "$rid" ]] && return 0
  curl -sS -X DELETE -H "Authorization: Bearer $DNS_CF_API_TOKEN" \
    "${DNS_CF_BASE}/zones/${DNS_CF_ZONE_ID}/dns_records/${rid}" >/dev/null
}

dns_get() {
  local name="$1" type="$2"
  curl -sS -H "Authorization: Bearer $DNS_CF_API_TOKEN" \
    "${DNS_CF_BASE}/zones/${DNS_CF_ZONE_ID}/dns_records?name=${name}&type=${type}" \
    | jq -c '.result[0] | if . then {value: .content, ttl: .ttl} else null end'
}
