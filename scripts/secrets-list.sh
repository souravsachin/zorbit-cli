#!/usr/bin/env bash
#
# secrets-list.sh — list platform secrets (metadata only).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_vault-lib.sh
source "${SCRIPT_DIR}/_vault-lib.sh"

PREFIX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: secrets-list.sh [--prefix <dotted.prefix>]
EOF
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

PATH_SUFFIX="/api/v1/G/secrets"
if [[ -n "${PREFIX}" ]]; then
  PATH_SUFFIX="${PATH_SUFFIX}?prefix=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' -- "${PREFIX}")"
fi

vault_call GET "${PATH_SUFFIX}"
echo
