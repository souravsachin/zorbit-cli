#!/usr/bin/env bash
# zorbit-cli/scripts/bootstrap-lib/common.sh
# Shared helpers: logging, execution gate, config loading.
# Sourced by bootstrap-env.sh and every other lib/*.sh file.
# ---------------------------------------------------------------------------

# Colors (auto-disable if not a TTY).
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_BOLD=""
fi

# Exit codes (shared).
EXIT_OK=0
EXIT_PREFLIGHT_FAIL=1
EXIT_USER_CANCEL=2
EXIT_ACCOUNT_GUARD=3
EXIT_DEPLOY_FAIL=4

# Timestamp for logs.
_ts() { date +'%Y-%m-%d %H:%M:%S'; }

log_info()  { printf '%s[INFO ]%s %s %s\n'  "${C_BLU}"  "${C_RESET}" "$(_ts)" "$*"; }
log_ok()    { printf '%s[ OK  ]%s %s %s\n'  "${C_GRN}"  "${C_RESET}" "$(_ts)" "$*"; }
log_warn()  { printf '%s[WARN ]%s %s %s\n'  "${C_YEL}"  "${C_RESET}" "$(_ts)" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s %s\n'  "${C_RED}"  "${C_RESET}" "$(_ts)" "$*" >&2; }
log_step()  { printf '\n%s==> %s%s\n' "${C_BOLD}${C_CYN}" "$*" "${C_RESET}"; }

# ---------------------------------------------------------------------------
# Execution gate: run commands only when not in dry-run.
# ---------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-false}"

run_cmd() {
  # Usage: run_cmd "description" command args...
  local desc="$1"; shift
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '%s[DRY  ]%s %s %s\n    $ %s\n' \
      "${C_YEL}" "${C_RESET}" "$(_ts)" "${desc}" "$*"
    return 0
  fi
  log_info "${desc}"
  printf '    %s$%s %s\n' "${C_CYN}" "${C_RESET}" "$*"
  "$@"
}

run_shell() {
  # Usage: run_shell "description" "shell pipeline here"
  local desc="$1"; shift
  local cmd="$*"
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '%s[DRY  ]%s %s %s\n    $ %s\n' \
      "${C_YEL}" "${C_RESET}" "$(_ts)" "${desc}" "${cmd}"
    return 0
  fi
  log_info "${desc}"
  printf '    %s$%s %s\n' "${C_CYN}" "${C_RESET}" "${cmd}"
  bash -c "${cmd}"
}

# ---------------------------------------------------------------------------
# Config: read YAML without external deps by shelling out to python3.
# Exports answers as globals.
# ---------------------------------------------------------------------------
REPO_ROOT_GUESS="${REPO_ROOT_GUESS:-${HOME}/workspace/zorbit/02_repos}"

yaml_get() {
  # Usage: yaml_get <file> <python-expr-on-data>
  # Example: yaml_get envs.yaml "data['progression_chain']"
  local file="$1"; local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import sys, yaml, json
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
result = eval(sys.argv[2], {"data": data})
if isinstance(result, (dict, list)):
    print(json.dumps(result))
else:
    print(result)
PY
}

# ---------------------------------------------------------------------------
# Prompt helpers.
# ---------------------------------------------------------------------------
ask() {
  # ask <var-name> <question> [default]
  local __var="$1"; local __q="$2"; local __default="${3:-}"
  local __answer
  if [[ -n "${__default}" ]]; then
    printf '%s?%s %s [%s]: ' "${C_CYN}" "${C_RESET}" "${__q}" "${__default}"
  else
    printf '%s?%s %s: ' "${C_CYN}" "${C_RESET}" "${__q}"
  fi
  read -r __answer
  [[ -z "${__answer}" ]] && __answer="${__default}"
  eval "${__var}=\"${__answer}\""
}

ask_yn() {
  # ask_yn <var-name> <question> [default y|n]
  local __var="$1"; local __q="$2"; local __default="${3:-n}"
  local __answer
  while true; do
    printf '%s?%s %s [y/n, default=%s]: ' "${C_CYN}" "${C_RESET}" "${__q}" "${__default}"
    read -r __answer
    [[ -z "${__answer}" ]] && __answer="${__default}"
    case "${__answer,,}" in
      y|yes) eval "${__var}=\"y\""; return 0;;
      n|no)  eval "${__var}=\"n\""; return 0;;
      *) log_warn "Answer y or n.";;
    esac
  done
}

ask_yn_with_help() {
  # ask_yn_with_help <var-name> <question> <yes-help> <no-help> [default y|n]
  #
  # Owner feedback 2026-04-23 (flaw 3): every y/n prompt must explain what
  # BOTH answers do before the user chooses. The two-line help block prints
  # immediately above the prompt so the operator never guesses.
  local __var="$1"; local __q="$2"; local __yes="$3"; local __no="$4"
  local __default="${5:-n}"

  printf '\n'
  printf '  %s[yes]%s %s\n' "${C_GRN}" "${C_RESET}" "${__yes}"
  printf '  %s[no ]%s %s\n' "${C_YEL}" "${C_RESET}" "${__no}"
  ask_yn "${__var}" "${__q}" "${__default}"
}

print_table_header() {
  printf '%-40s | %-10s | %s\n' "$1" "$2" "$3"
  printf '%s\n' "--------------------------------------------------------------------------------"
}
print_table_row() {
  printf '%-40s | %-10s | %s\n' "$1" "$2" "$3"
}
