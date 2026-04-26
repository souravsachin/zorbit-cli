#!/usr/bin/env bash
# =============================================================================
# scripts/install/lib/prompt.sh
#
# Tasksel-style [F]ix / [S]kip / [Q]uit prompts for prereq self-fix UX.
#
# Skipped automatically when --yes / non-interactive mode is on (via
# INSTALL_NON_INTERACTIVE=1). In that mode:
#   - "fix" branch is taken if a fix_fn was provided
#   - else "skip" is taken
# This makes CI-friendly runs deterministic.
#
# Sourced — does not set -e.
# =============================================================================

# prompt_fix_skip_quit "title" "instructions" "fix_fn_or_empty"
# Returns:
#   0 = fixed (fix_fn ran successfully)
#   1 = skipped
#   2 = fix_fn ran but failed
# Quit calls exit 2 directly.
prompt_fix_skip_quit() {
  local title="$1"
  local instructions="$2"
  local fix_fn="${3:-}"

  echo "  ${UI_RED}✗${UI_NC} $title"
  while IFS= read -r line; do
    echo "      ${UI_DIM}┃${UI_NC}  $line"
  done <<< "$instructions"

  if [[ -n "$fix_fn" ]]; then
    echo "      ${UI_BOLD}[F]${UI_NC}ix now (run $fix_fn)   ${UI_BOLD}[S]${UI_NC}kip   ${UI_BOLD}[Q]${UI_NC}uit"
  else
    echo "      ${UI_BOLD}[S]${UI_NC}kip   ${UI_BOLD}[Q]${UI_NC}uit (no auto-fix available — fix manually then re-run)"
  fi

  # Non-interactive: auto-decide.
  if [[ "${INSTALL_NON_INTERACTIVE:-0}" = "1" ]]; then
    if [[ -n "$fix_fn" ]]; then
      echo "      ${UI_DIM}(non-interactive: auto-F)${UI_NC}"
      if "$fix_fn"; then return 0; else return 2; fi
    else
      echo "      ${UI_DIM}(non-interactive: auto-S)${UI_NC}"
      return 1
    fi
  fi

  # If stdin isn't a tty, we can't prompt — fail safe by skipping.
  if [[ ! -t 0 ]]; then
    echo "      ${UI_DIM}(stdin not a tty: auto-S)${UI_NC}"
    return 1
  fi

  local ans
  while true; do
    if ! read -r -p "      Choose [F/S/Q]: " ans; then
      # EOF on stdin — treat as skip.
      return 1
    fi
    case "${ans,,}" in
      f|fix)
        if [[ -n "$fix_fn" ]]; then
          if "$fix_fn"; then return 0; else return 2; fi
        else
          echo "      no fix function — pick S or Q"
        fi
        ;;
      s|skip) return 1 ;;
      q|quit) echo "  Aborting at user request."; exit 2 ;;
      *) echo "      enter F, S, or Q" ;;
    esac
  done
}

# Confirm yes/no, default Y unless DEFAULT_NO=1
prompt_yes_no() {
  local question="$1"
  local default="${2:-Y}"

  if [[ "${INSTALL_NON_INTERACTIVE:-0}" = "1" ]]; then
    [[ "$default" = "Y" ]] && return 0 || return 1
  fi

  local hint
  if [[ "$default" = "Y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi

  local ans
  read -r -p "  $question $hint: " ans
  ans="${ans:-$default}"
  case "${ans,,}" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}
