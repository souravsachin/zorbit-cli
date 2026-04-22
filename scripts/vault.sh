#!/usr/bin/env bash
#
# vault.sh — Zorbit Secrets Vault CLI dispatcher.
#
# Subcommands:
#   put       Create/update a secret. Prompts for key + value via read -s.
#   get       Read a secret. --mask to hide value in terminal output.
#   list      List secrets by optional prefix (metadata only).
#   rotate    Trigger a rotation (prompts for the new value via read -s).
#   versions  List version history of a key.
#   delete    Soft-delete a secret.
#
# Environment:
#   ZORBIT_VAULT_URL          base URL (default: http://localhost:3038)
#   ZORBIT_VAULT_API_PREFIX   prefix (default: ""). Set to /api/secrets_vault
#                             when going through nginx.
#   ZORBIT_VAULT_TOKEN        bearer JWT. Falls back to:
#   ZORBIT_VAULT_TOKEN_FILE   default: /opt/zorbit-platform/secrets_vault/bootstrap.jwt
#
# Exit codes:
#   0  success
#   1  usage / subcommand error
#   2  vault returned non-2xx
#
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <subcommand> [args]

Subcommands:
  put           Create/update a secret (interactive, stdin-masked).
  get [--mask]  Read a secret. --mask redacts the output.
  list          List secret meta; takes optional --prefix.
  rotate        Rotate a secret (interactive).
  versions      List version history of a key.
  delete        Soft-delete a secret.

Env: ZORBIT_VAULT_URL, ZORBIT_VAULT_API_PREFIX, ZORBIT_VAULT_TOKEN,
     ZORBIT_VAULT_TOKEN_FILE.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

sub="$1"; shift || true

case "${sub}" in
  put)       exec "${BASE_DIR}/secrets-put.sh" "$@" ;;
  get)       exec "${BASE_DIR}/secrets-get.sh" "$@" ;;
  list|ls)   exec "${BASE_DIR}/secrets-list.sh" "$@" ;;
  rotate)    exec "${BASE_DIR}/secrets-rotate.sh" "$@" ;;
  versions)  exec "${BASE_DIR}/secrets-versions.sh" "$@" ;;
  delete|rm) exec "${BASE_DIR}/secrets-delete.sh" "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *)
    echo "unknown subcommand: ${sub}" >&2
    usage
    exit 1
    ;;
esac
