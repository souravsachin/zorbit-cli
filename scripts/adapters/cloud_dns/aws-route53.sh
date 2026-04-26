#!/usr/bin/env bash
# =============================================================================
# scripts/adapters/cloud_dns/aws-route53.sh
#
# Cloud-DNS adapter — AWS Route 53 via the `aws` CLI.
#
# Contract:
#   dns_check                    — adapter usable here? (returns 0/1)
#   dns_upsert <name> <type> <value> [ttl]
#   dns_delete <name> <type>
#   dns_get <name> <type>        — outputs JSON {value, ttl}
#
# Required env:
#   DNS_AWS_ZONE_ID    Route 53 hosted zone id
# =============================================================================

DNS_AWS_ZONE_ID="${DNS_AWS_ZONE_ID:-}"

dns_check() {
  command -v aws >/dev/null 2>&1 || { echo "  aws-route53: aws CLI not installed" >&2; return 1; }
  aws sts get-caller-identity >/dev/null 2>&1 \
    || { echo "  aws-route53: aws sts get-caller-identity failed (creds not configured)" >&2; return 1; }
  [[ -n "$DNS_AWS_ZONE_ID" ]] \
    || { echo "  aws-route53: DNS_AWS_ZONE_ID env var not set" >&2; return 1; }
  return 0
}

dns_upsert() {
  local name="$1" type="$2" value="$3" ttl="${4:-300}"
  local change
  change=$(jq -nc \
    --arg n "$name" --arg t "$type" --arg v "$value" --argjson ttl "$ttl" \
    '{Changes:[{Action:"UPSERT", ResourceRecordSet:{Name:$n, Type:$t, TTL:$ttl, ResourceRecords:[{Value:$v}]}}]}')
  aws route53 change-resource-record-sets --hosted-zone-id "$DNS_AWS_ZONE_ID" --change-batch "$change" >/dev/null
}

dns_delete() {
  local name="$1" type="$2"
  # First read the existing record to construct the DELETE change.
  local existing
  existing="$(dns_get "$name" "$type")"
  [[ "$existing" = "null" || -z "$existing" ]] && return 0
  local value ttl
  value="$(echo "$existing" | jq -r '.value')"
  ttl="$(echo "$existing" | jq -r '.ttl')"
  local change
  change=$(jq -nc --arg n "$name" --arg t "$type" --arg v "$value" --argjson ttl "$ttl" \
    '{Changes:[{Action:"DELETE", ResourceRecordSet:{Name:$n, Type:$t, TTL:$ttl, ResourceRecords:[{Value:$v}]}}]}')
  aws route53 change-resource-record-sets --hosted-zone-id "$DNS_AWS_ZONE_ID" --change-batch "$change" >/dev/null
}

dns_get() {
  local name="$1" type="$2"
  aws route53 list-resource-record-sets --hosted-zone-id "$DNS_AWS_ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${name}.' && Type=='${type}']" --output json 2>/dev/null \
    | jq -c '.[0] | if . then {value: .ResourceRecords[0].Value, ttl: .TTL} else null end'
}
