#!/usr/bin/env bash
#
# secrets-rotate.sh — rotate a platform secret (writes a new version).
# Value read via stdin with echo disabled; confirmation required if tty.
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
      cat <<EOF
Usage: secrets-rotate.sh [--key <dotted.key.path>]
EOF
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${KEY}" ]]; then
  read -r -p 'key to rotate: ' KEY
fi

VALUE="$(read_secret_value 'new value (hidden)> ')"
if [[ -z "${VALUE}" ]]; then
  echo "value must be non-empty" >&2
  exit 1
fi
if [[ -t 0 ]]; then
  CONFIRM="$(read_secret_value 'confirm new value (hidden)> ')"
  if [[ "${VALUE}" != "${CONFIRM}" ]]; then
    echo "values do not match — aborting" >&2
    exit 1
  fi
fi

VAL_JSON="$(json_escape "${VALUE}")"
BODY="{\"value\":${VAL_JSON}}"

vault_call PATCH "/api/v1/G/secrets/${KEY}" "${BODY}"
echo
