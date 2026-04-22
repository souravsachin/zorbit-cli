#!/usr/bin/env bash
#
# _vault-lib.sh — shared helpers for secrets-*.sh CLI commands.
# Source, don't exec.
#
# Exposes: vault_url, vault_token, vault_call <method> <path> [body]
#

vault_url() {
  local base="${ZORBIT_VAULT_URL:-http://localhost:3038}"
  local prefix="${ZORBIT_VAULT_API_PREFIX:-}"
  echo "${base%/}${prefix}"
}

vault_token() {
  if [[ -n "${ZORBIT_VAULT_TOKEN:-}" ]]; then
    echo "${ZORBIT_VAULT_TOKEN}"
    return
  fi
  local path="${ZORBIT_VAULT_TOKEN_FILE:-/opt/zorbit-platform/secrets_vault/bootstrap.jwt}"
  if [[ -f "${path}" ]]; then
    tr -d '[:space:]' < "${path}"
    return
  fi
  echo "" # caller handles empty
}

# $1 = HTTP method   $2 = path (starts with /api/...)   $3 = optional body
vault_call() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local url token
  url="$(vault_url)${path}"
  token="$(vault_token)"
  if [[ -z "${token}" ]]; then
    echo "error: no ZORBIT_VAULT_TOKEN and no bootstrap JWT found." >&2
    return 2
  fi
  local tmp_body tmp_code
  tmp_body="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp_body}'" RETURN
  local args=(
    -sS
    --connect-timeout 5
    --max-time 15
    -o "${tmp_body}"
    -w '%{http_code}'
    -H "Authorization: Bearer ${token}"
    -X "${method}"
  )
  if [[ -n "${body}" ]]; then
    args+=(-H 'Content-Type: application/json' --data-raw "${body}")
  fi
  args+=("${url}")
  local code
  code="$(curl "${args[@]}" || true)"
  if [[ "${code}" != 2* ]]; then
    echo "error: ${method} ${path} → HTTP ${code}" >&2
    if [[ -s "${tmp_body}" ]]; then cat "${tmp_body}" >&2; echo >&2; fi
    return 2
  fi
  cat "${tmp_body}"
  return 0
}

# Read a value from stdin without echoing, using -s.
# On unexpected Ctrl-C, terminal stays visible (trap resets stty).
read_secret_value() {
  local prompt="${1:-value> }"
  local val
  printf '%s' "${prompt}" >&2
  # trap ensures we turn echo back on if interrupted
  trap 'stty echo 2>/dev/null || true' EXIT INT TERM
  if [[ -t 0 ]]; then
    IFS= read -rs val < /dev/tty
  else
    IFS= read -r val
  fi
  echo >&2
  trap - EXIT INT TERM
  printf '%s' "${val}"
}

# JSON-escape a string for inclusion in a request body.
# Uses argv (not stdin) so trailing newlines in the value are preserved
# exactly as provided.
json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' -- "$1"
}
