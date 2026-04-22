#!/usr/bin/env bash
#
# secrets-get.sh — read a platform secret.
# Use --mask to redact the value in terminal output.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_vault-lib.sh
source "${SCRIPT_DIR}/_vault-lib.sh"

KEY=""
VERSION=""
MASK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --mask) MASK=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: secrets-get.sh [--key <dotted.key.path>] [--version <N>] [--mask]

If --key is omitted, you'll be prompted. With --mask, the value is
shown as the first 2 and last 2 chars with "****" in between.
EOF
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${KEY}" ]]; then
  read -r -p 'key: ' KEY
fi

PATH_SUFFIX="/api/v1/G/secrets/${KEY}"
if [[ -n "${VERSION}" ]]; then
  PATH_SUFFIX="${PATH_SUFFIX}?version=${VERSION}"
fi

BODY="$(vault_call GET "${PATH_SUFFIX}")"

if [[ "${MASK}" == "true" ]]; then
  python3 <<PY
import json,sys
b = json.loads(${BODY@Q})
v = b.get("value","")
if len(v) <= 6:
    masked = "****"
else:
    masked = v[:2] + "****" + v[-2:]
b["value"] = masked
print(json.dumps(b, indent=2))
PY
else
  echo "${BODY}"
fi
