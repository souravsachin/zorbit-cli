#!/usr/bin/env bash
# =============================================================================
# scripts/install/layer-1-prereqs.sh
#
# Layer 1 — prereq check + tasksel-style self-fix.
#
# This layer is **vendor-neutral**: it only checks for tools that the
# orchestrator itself needs (jq, curl, ssh-agent, sudo NOPASSWD on the
# local machine, etc.).
#
# Provider-specific prereqs (cloud CLI auth, hypervisor SSH access, DNS API
# tokens) are checked by each adapter's own `<kind>_check` function — they
# are NOT named here, satisfying the strict-genericity rule.
#
# Each prereq has:
#   - description: one-line human label
#   - check_fn:    returns 0 if satisfied
#   - fix_fn:      returns 0 if the fix is safe to run unattended (optional)
#   - instructions: shown if no fix_fn (string)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ "$(type -t ui_ok 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck disable=SC1091
[[ "$(type -t state_layer_set 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck disable=SC1091
[[ "$(type -t prompt_fix_skip_quit 2>/dev/null)" = "function" ]] || source "${SCRIPT_DIR}/lib/prompt.sh"

# ---- prereq checks ---------------------------------------------------------

prereq_jq_check()      { command -v jq      >/dev/null 2>&1; }
prereq_curl_check()    { command -v curl    >/dev/null 2>&1; }
prereq_ssh_check()     { command -v ssh     >/dev/null 2>&1; }
prereq_git_check()     { command -v git     >/dev/null 2>&1; }
prereq_docker_check()  { command -v docker  >/dev/null 2>&1; }

prereq_ssh_agent_check() {
  [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh-add -l >/dev/null 2>&1
}

prereq_sudo_check() {
  # Either we are root, or we have at least one NOPASSWD entry, or sudo -n
  # accepts a benign command.
  [[ $EUID -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null
}

prereq_internet_check() {
  curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://www.google.com 2>/dev/null \
    | grep -qE '^(200|301|302|307)$'
}

# ---- prereq fix functions (only safe ones) ---------------------------------

prereq_jq_fix() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y jq
  elif command -v brew >/dev/null 2>&1; then
    brew install jq
  else
    return 1
  fi
}

prereq_curl_fix() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y curl
  elif command -v brew >/dev/null 2>&1; then
    brew install curl
  else
    return 1
  fi
}

# ---- driver ---------------------------------------------------------------

# Each entry: NAME|DESCRIPTION|CHECK_FN|FIX_FN_OR_EMPTY|INSTRUCTIONS
PREREQ_LIST=(
  "jq|jq JSON parser|prereq_jq_check|prereq_jq_fix|Install jq via your package manager (apt-get install jq / brew install jq)."
  "curl|curl HTTP client|prereq_curl_check|prereq_curl_fix|Install curl via your package manager."
  "ssh|ssh client|prereq_ssh_check||Install openssh-client via your package manager."
  "git|git VCS|prereq_git_check||Install git via your package manager (apt-get install git / brew install git)."
  "ssh-agent|ssh-agent has at least one key loaded|prereq_ssh_agent_check||Run: eval \$(ssh-agent) && ssh-add ~/.ssh/id_ed25519"
  "sudo|sudo available (or running as root)|prereq_sudo_check||Install sudo and add your user to sudoers, or run as root."
  "internet|outbound HTTPS works|prereq_internet_check||Check your network — installer pulls images, repos, and CLI tools."
  "docker|docker CLI installed|prereq_docker_check||Layer 3 will install docker on the target VM if missing — locally only required if running container-mode."
)

layer_1_prereqs() {
  state_layer_set "1_prereqs" "running"

  local total_ok=0
  local total_fail=0
  local total=${#PREREQ_LIST[@]}
  declare -A results=()

  for entry in "${PREREQ_LIST[@]}"; do
    IFS='|' read -r name desc check_fn fix_fn instructions <<< "$entry"
    if "$check_fn"; then
      ui_ok "$desc"
      results["$name"]="ok"
      total_ok=$((total_ok + 1))
    else
      results["$name"]="fail"
      total_fail=$((total_fail + 1))
      if prompt_fix_skip_quit "$desc" "$instructions" "$fix_fn"; then
        # Re-check after fix
        if "$check_fn"; then
          ui_ok "$desc (fixed)"
          results["$name"]="fixed"
          total_ok=$((total_ok + 1)); total_fail=$((total_fail - 1))
        else
          ui_warn "$desc still failing after fix attempt"
        fi
      fi
    fi
  done

  echo
  ui_info "${total_ok}/${total} prereqs satisfied. ${total_fail} need attention."

  # Stash results.
  local results_json="{}"
  for k in "${!results[@]}"; do
    results_json=$(echo "$results_json" | jq --arg k "$k" --arg v "${results[$k]}" '. + {($k): $v}')
  done
  state_layer_data "1_prereqs" "$results_json"

  if [[ "$total_fail" -gt 0 ]]; then
    if [[ "${INSTALL_SKIP_PREREQS:-0}" = "1" ]]; then
      ui_warn "prereq failures bypassed via --skip-prereqs"
      state_layer_set "1_prereqs" "skipped"
    else
      state_layer_set "1_prereqs" "failed"
      if [[ "${INSTALL_CHECK_ONLY:-0}" != "1" ]]; then
        ui_die "Prereq check failed. Fix the items above and re-run, or pass --skip-prereqs to bypass at your own risk."
      fi
    fi
  else
    state_layer_set "1_prereqs" "done"
  fi
}
