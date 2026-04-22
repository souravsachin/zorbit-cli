#!/usr/bin/env bash
#
# secrets-delete.sh — soft-delete a platform secret.
# History is preserved; subsequent reads return 404.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_vault-lib.sh
source "${SCRIPT_DIR}/_vault-lib.sh"

KEY=""
FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      echo "Usage: secrets-delete.sh [--key <dotted.key.path>] [--force]"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${KEY}" ]]; then
  read -r -p 'key to delete: ' KEY
fi

if [[ "${FORCE}" != "true" ]] && [[ -t 0 ]]; then
  read -r -p "soft-delete ${KEY}? [y/N] " ANS
  case "${ANS}" in
    y|Y|yes|YES) ;;
    *) echo "aborted."; exit 0 ;;
  esac
fi

vault_call DELETE "/api/v1/G/secrets/${KEY}"
echo
