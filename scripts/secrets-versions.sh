#!/usr/bin/env bash
#
# secrets-versions.sh — list version history of a secret.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_vault-lib.sh
source "${SCRIPT_DIR}/_vault-lib.sh"

KEY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: secrets-versions.sh [--key <dotted.key.path>]"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "${KEY}" ]]; then
  read -r -p 'key: ' KEY
fi

vault_call GET "/api/v1/G/secrets/${KEY}/versions"
echo
