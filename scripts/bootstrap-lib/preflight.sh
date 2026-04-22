#!/usr/bin/env bash
# zorbit-cli/scripts/bootstrap-lib/preflight.sh
# Preflight checks before any state-changing operation runs.
# Each check emits (name, ok/fail, fix-hint) and updates the PREFLIGHT_FAIL counter.
# ---------------------------------------------------------------------------

PREFLIGHT_FAIL=0
PREFLIGHT_RESULTS=()   # array of "name|status|hint"

_check() {
  # _check "name" "pass|fail" "hint-if-fail"
  local name="$1"; local status="$2"; local hint="$3"
  PREFLIGHT_RESULTS+=("${name}|${status}|${hint}")
  if [[ "${status}" != "pass" ]]; then
    PREFLIGHT_FAIL=$((PREFLIGHT_FAIL + 1))
  fi
}

check_docker() {
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      _check "docker-daemon" "pass" ""
    else
      _check "docker-daemon" "fail" "Start docker: sudo systemctl start docker"
    fi
  else
    _check "docker-daemon" "fail" "Install docker: see bootstrap-env-root.sh"
  fi

  if docker compose version >/dev/null 2>&1; then
    _check "docker-compose-plugin" "pass" ""
  else
    _check "docker-compose-plugin" "fail" "apt install -y docker-compose-plugin"
  fi
}

check_node() {
  if command -v node >/dev/null 2>&1; then
    local ver
    ver="$(node --version | sed 's/v//' | cut -d. -f1)"
    if [[ "${ver}" -ge 18 ]]; then
      _check "node>=18" "pass" ""
    else
      _check "node>=18" "fail" "Install node 20: nvm install 20 && nvm use 20"
    fi
  else
    _check "node>=18" "fail" "Install node 20: curl -sL https://deb.nodesource.com/setup_20.x | sudo bash - && apt install -y nodejs"
  fi
}

check_python() {
  if command -v python3 >/dev/null 2>&1; then
    local ver
    ver="$(python3 -c 'import sys; print(sys.version_info[0]*100+sys.version_info[1])')"
    if [[ "${ver}" -ge 310 ]]; then
      _check "python>=3.10" "pass" ""
    else
      _check "python>=3.10" "fail" "apt install -y python3.10"
    fi
  else
    _check "python>=3.10" "fail" "apt install -y python3"
  fi

  if python3 -c 'import yaml' 2>/dev/null; then
    _check "python-yaml" "pass" ""
  else
    _check "python-yaml" "fail" "pip3 install pyyaml  (or apt install -y python3-yaml)"
  fi
}

check_git_gh_ssh() {
  if command -v git >/dev/null 2>&1; then
    _check "git" "pass" ""
  else
    _check "git" "fail" "apt install -y git"
  fi

  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      _check "gh-cli-auth" "pass" ""
    else
      _check "gh-cli-auth" "fail" "gh auth login"
    fi
  else
    _check "gh-cli-auth" "fail" "Install gh: https://cli.github.com/"
  fi

  if [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh-add -l >/dev/null 2>&1; then
    _check "ssh-agent-keys" "pass" ""
  else
    _check "ssh-agent-keys" "fail" "eval \$(ssh-agent) && ssh-add ~/.ssh/id_ed25519"
  fi
}

check_disk_space() {
  local path="$1"
  local parent
  parent="$(dirname "${path}")"
  [[ -d "${parent}" ]] || parent="/"
  local free_gb
  # Portable: Linux df supports -BG; macOS df doesn't. Fall back to -k.
  if df -BG "${parent}" >/dev/null 2>&1; then
    free_gb=$(df -BG "${parent}" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
  else
    # -k gives 1K blocks on macOS; divide by 1024/1024 for GB.
    free_gb=$(df -k "${parent}" | awk 'NR==2 {printf "%d", $4/1024/1024}')
  fi
  if [[ "${free_gb}" =~ ^[0-9]+$ ]] && [[ "${free_gb}" -ge 30 ]]; then
    _check "disk>=30GB @ ${parent}" "pass" ""
  else
    _check "disk>=30GB @ ${parent}" "fail" "Free up space or use a different path (have ${free_gb}G)"
  fi
}

check_ports() {
  # Check 80, 443, and a few in the 3000-3099 range.
  local ports=(80 443 3000 3001 3002 3003 3004 3005)
  local in_use=()
  for p in "${ports[@]}"; do
    if command -v ss >/dev/null 2>&1; then
      if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"; then
        in_use+=("${p}")
      fi
    elif command -v lsof >/dev/null 2>&1; then
      if lsof -iTCP:"${p}" -sTCP:LISTEN -P -n >/dev/null 2>&1; then
        in_use+=("${p}")
      fi
    fi
  done
  if [[ ${#in_use[@]} -eq 0 ]]; then
    _check "ports-free (80,443,3000-3005)" "pass" ""
  else
    _check "ports-free (80,443,3000-3005)" "fail" "Ports busy: ${in_use[*]} — stop conflicting services"
  fi
}

check_service_account() {
  local allowed_pattern="$1"   # regex
  local current_user
  current_user="$(whoami)"
  local override="${ZORBIT_SERVICE_USER:-}"

  if [[ -n "${override}" ]] && [[ "${current_user}" == "${override}" ]]; then
    _check "service-account" "pass" ""
    return 0
  fi

  if [[ "${current_user}" =~ ${allowed_pattern} ]]; then
    _check "service-account" "pass" ""
    return 0
  fi

  _check "service-account" "fail" \
    "Run as zorbit-deployer: sudo -u zorbit-deployer -i ./bootstrap-env.sh (or set ZORBIT_SERVICE_USER=${current_user})"
  return 1
}

print_preflight_report() {
  echo ""
  log_step "Preflight Report"
  print_table_header "Check" "Status" "Fix if failed"
  local row name status hint symbol
  for row in "${PREFLIGHT_RESULTS[@]}"; do
    IFS='|' read -r name status hint <<<"${row}"
    if [[ "${status}" == "pass" ]]; then
      symbol="${C_GRN}PASS${C_RESET}"
    else
      symbol="${C_RED}FAIL${C_RESET}"
    fi
    print_table_row "${name}" "${symbol}" "${hint}"
  done
  echo ""
  if [[ "${PREFLIGHT_FAIL}" -gt 0 ]]; then
    log_error "${PREFLIGHT_FAIL} preflight check(s) failed."
  else
    log_ok "All preflight checks passed."
  fi
}
