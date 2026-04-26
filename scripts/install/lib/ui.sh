#!/usr/bin/env bash
# =============================================================================
# scripts/install/lib/ui.sh
#
# Banner + status + color helpers for `zorbit install`.
#
# Owner directive MSG-097 (2026-04-27): banner must spell ZORBIT correctly
# (six letters, Z-O-R-B-I-T). Earlier draft mis-spelled it "ZORBST" by
# fudging letters 5 (I) and 6 (T) — verified against the canonical version
# below before shipping.
#
# This file is sourced — it must NOT call `set -euo pipefail`, that is the
# caller's responsibility.
# =============================================================================

# Color codes — only emit if stdout is a tty.
if [[ -t 1 ]]; then
  UI_RED=$'\033[0;31m'
  UI_GREEN=$'\033[0;32m'
  UI_YELLOW=$'\033[1;33m'
  UI_BLUE=$'\033[0;34m'
  UI_CYAN=$'\033[0;36m'
  UI_BOLD=$'\033[1m'
  UI_DIM=$'\033[2m'
  UI_NC=$'\033[0m'
else
  UI_RED=""; UI_GREEN=""; UI_YELLOW=""; UI_BLUE=""; UI_CYAN=""
  UI_BOLD=""; UI_DIM=""; UI_NC=""
fi

ui_banner() {
  # ASCII spelling Z O R B I T (verified column-by-column).
  cat <<'BANNER'

   _____  ___  ____  ____ ___ _____
  |__  / / _ \|  _ \| __ )_ _|_   _|
    / /  | | | | |_) |  _ \| |   | |
   / /_  | |_| |  _ <| |_) | |   | |
  /____|  \___/|_| \_\____/___|  |_|

BANNER
  echo "  ${UI_BOLD}The Zorbit unified installer${UI_NC}"
  echo "  ${UI_DIM}Layer-aware  ·  Adapter-pluggable  ·  Idempotent${UI_NC}"
  echo
}

ui_section() {
  local title="$1"
  echo
  echo "${UI_BOLD}${UI_CYAN}═══ $title ═══${UI_NC}"
}

ui_layer_header() {
  local n="$1" total="$2" name="$3"
  echo
  echo "${UI_BOLD}${UI_BLUE}[layer ${n}/${total}] ${name}${UI_NC}"
}

ui_ok()    { echo "  ${UI_GREEN}✓${UI_NC} $*"; }
ui_fail()  { echo "  ${UI_RED}✗${UI_NC} $*"; }
ui_warn()  { echo "  ${UI_YELLOW}⚠${UI_NC} $*"; }
ui_info()  { echo "  ${UI_CYAN}·${UI_NC} $*"; }
ui_step()  { echo "  ${UI_DIM}┃${UI_NC}  $*"; }

ui_die() {
  echo "${UI_RED}${UI_BOLD}✗ FATAL:${UI_NC} $*" >&2
  exit 1
}

# Pretty-print a status table row: "name | status | detail"
ui_row() {
  local name="$1" status="$2" detail="${3:-}"
  local marker
  case "$status" in
    ok|done|pass) marker="${UI_GREEN}✓${UI_NC}";;
    fail|error)   marker="${UI_RED}✗${UI_NC}";;
    skip|pending) marker="${UI_YELLOW}-${UI_NC}";;
    running)      marker="${UI_CYAN}●${UI_NC}";;
    *)            marker="${UI_DIM}?${UI_NC}";;
  esac
  printf "  %s %-32s %s\n" "$marker" "$name" "$detail"
}

# Progress bar: ui_progress 3 7 "layer 4: shared infra"
ui_progress() {
  local cur="$1" total="$2" label="$3"
  local pct=$(( cur * 100 / (total > 0 ? total : 1) ))
  local bar_width=30
  local filled=$(( cur * bar_width / (total > 0 ? total : 1) ))
  local empty=$(( bar_width - filled ))
  local bar
  bar="$(printf '#%.0s' $(seq 1 $filled 2>/dev/null || true))"
  bar+="$(printf '.%.0s' $(seq 1 $empty 2>/dev/null || true))"
  printf "  ${UI_BOLD}[%-${bar_width}s]${UI_NC} %3d%%  %s\n" "$bar" "$pct" "$label"
}
