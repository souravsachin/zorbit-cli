#!/usr/bin/env bash
# =============================================================================
# scripts/adapters/auth_provider/github-gh.sh
#
# Auth provider — GitHub via the `gh` CLI.
#
# Contract:
#   auth_check                       — gh authenticated with required scopes?
#   auth_fix                         — kick off `gh auth refresh` to add scopes
#   auth_required_scopes_default     — print the default scopes we expect
#
# Required scopes (default):
#   read:packages, write:packages    — for ghcr.io image push/pull
#   repo                             — for cloning private repos
# =============================================================================

AUTH_REQUIRED_SCOPES="${AUTH_REQUIRED_SCOPES:-read:packages,write:packages,repo}"

auth_check() {
  command -v gh >/dev/null 2>&1 || { echo "  github-gh: gh CLI not installed" >&2; return 1; }
  if ! gh auth status >/dev/null 2>&1; then
    echo "  github-gh: not authenticated (run 'gh auth login')" >&2
    return 1
  fi
  # Check scopes.
  local scopes
  scopes="$(gh auth status 2>&1 | grep -i 'token scopes' | head -1)"
  local missing=""
  IFS=',' read -ra need <<< "$AUTH_REQUIRED_SCOPES"
  for s in "${need[@]}"; do
    s="${s// /}"
    if ! echo "$scopes" | grep -q "$s"; then
      missing+="$s "
    fi
  done
  if [[ -n "$missing" ]]; then
    echo "  github-gh: missing scopes: $missing" >&2
    return 1
  fi
  return 0
}

auth_fix() {
  echo "  github-gh: running 'gh auth refresh -s $AUTH_REQUIRED_SCOPES'"
  gh auth refresh -s "$AUTH_REQUIRED_SCOPES"
}

auth_required_scopes_default() {
  echo "$AUTH_REQUIRED_SCOPES"
}
