#!/usr/bin/env bash
#
# secrets-put.sh — create or update a platform secret interactively.
# Value is read via stdin with echo disabled (never lands in shell history).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_vault-lib.sh
source "${SCRIPT_DIR}/_vault-lib.sh"

KEY=""
DESC=""
VALUE_FROM_STDIN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="$2"; shift 2 ;;
    --description) DESC="$2"; shift 2 ;;
    --value-stdin) VALUE_FROM_STDIN=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: secrets-put.sh [--key <dotted.key.path>] [--description <text>] [--value-stdin]

If --key is omitted, you'll be prompted.
Value is always read from stdin with echo disabled, so it never appears
in shell history or terminal scrollback.
EOF
      exit 0 ;;
    *)
      echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${KEY}" ]]; then
  read -r -p 'key (e.g. platform.zorbit-cor-identity.credentials.db-main): ' KEY
fi
if [[ -z "${KEY}" ]]; then
  echo "key is required" >&2
  exit 1
fi

VALUE="$(read_secret_value 'value (hidden)> ')"
if [[ -z "${VALUE}" ]]; then
  echo "value must be non-empty" >&2
  exit 1
fi

# Re-enter for confirmation (not tested interactively when not a tty).
if [[ -t 0 ]]; then
  CONFIRM="$(read_secret_value 'confirm value (hidden)> ')"
  if [[ "${VALUE}" != "${CONFIRM}" ]]; then
    echo "values do not match — aborting" >&2
    exit 1
  fi
fi

KEY_JSON="$(json_escape "${KEY}")"
VAL_JSON="$(json_escape "${VALUE}")"
DESC_JSON='null'
if [[ -n "${DESC}" ]]; then DESC_JSON="$(json_escape "${DESC}")"; fi

BODY="{\"key\":${KEY_JSON},\"value\":${VAL_JSON},\"description\":${DESC_JSON}}"

vault_call POST "/api/v1/G/secrets" "${BODY}"
echo
