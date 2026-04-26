#!/usr/bin/env bash
# =============================================================================
# scripts/install/lib/state.sh
#
# JSON state-file IO for `zorbit install`.
#
# Default location: /etc/zorbit/install-state.json (system-wide)
# Override via INSTALL_STATE_FILE env var (used by tests + dry-runs).
#
# State schema (v1.0):
#   {
#     "schema_version": "1.0",
#     "env_name": "qa",
#     "started_at": "2026-04-27T03:50:00Z",
#     "adapters": {
#       "hypervisor": "<adapter-name>",
#       "cloud_dns":  "<adapter-name>",
#       ...
#     },
#     "layers": {
#       "0_detect":    { "status": "done", "runtime": "host", "completed_at": "..." },
#       "1_prereqs":   { "status": "done", "results": { ... } },
#       "2_provision": { "status": "running", "started_at": "..." }
#       ...
#     }
#   }
#
# Layer status enum: pending | running | done | failed | skipped
#
# Sourced by `zorbit-install`. Requires `jq`.
# =============================================================================

INSTALL_STATE_FILE="${INSTALL_STATE_FILE:-/etc/zorbit/install-state.json}"
INSTALL_STATE_SCHEMA_VERSION="1.0"

# Ensure state file exists and is valid JSON. Creates parent dir if needed.
state_init() {
  local env_name="$1"
  local dir
  dir="$(dirname "$INSTALL_STATE_FILE")"

  # If file exists, validate it parses as JSON.
  if [[ -f "$INSTALL_STATE_FILE" ]]; then
    if ! jq -e . "$INSTALL_STATE_FILE" >/dev/null 2>&1; then
      ui_die "State file $INSTALL_STATE_FILE exists but is not valid JSON. Move/remove it and re-run."
    fi
    return 0
  fi

  if [[ ! -d "$dir" ]]; then
    if ! mkdir -p "$dir" 2>/dev/null; then
      # Fall back: try sudo for system-wide /etc/zorbit case.
      if command -v sudo >/dev/null 2>&1; then
        sudo mkdir -p "$dir" || ui_die "Cannot create $dir (need sudo)"
        sudo chown "$(id -u):$(id -g)" "$dir" 2>/dev/null || true
      else
        ui_die "Cannot create $dir"
      fi
    fi
  fi

  jq -n \
    --arg ver "$INSTALL_STATE_SCHEMA_VERSION" \
    --arg env "$env_name" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version: $ver, env_name: $env, started_at: $started, adapters: {}, layers: {}}' \
    > "$INSTALL_STATE_FILE"
}

# Read top-level field — usage: state_get .env_name
state_get() {
  local path="$1"
  jq -r "$path // \"\"" "$INSTALL_STATE_FILE" 2>/dev/null || echo ""
}

# Read full layer status — usage: state_layer_status 0_detect
state_layer_status() {
  local layer="$1"
  jq -r ".layers[\"$layer\"].status // \"pending\"" "$INSTALL_STATE_FILE" 2>/dev/null || echo "pending"
}

# Mark layer status — usage: state_layer_set 1_prereqs running
state_layer_set() {
  local layer="$1" status="$2"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp="${INSTALL_STATE_FILE}.tmp"
  jq \
    --arg l "$layer" \
    --arg s "$status" \
    --arg t "$now" \
    '.layers[$l] = (.layers[$l] // {}) | .layers[$l].status = $s | .layers[$l].updated_at = $t | (if $s == "running" then .layers[$l].started_at = $t else . end) | (if $s == "done" or $s == "failed" or $s == "skipped" then .layers[$l].completed_at = $t else . end)' \
    "$INSTALL_STATE_FILE" > "$tmp" && mv "$tmp" "$INSTALL_STATE_FILE"
}

# Stash arbitrary JSON under a layer's key — usage: state_layer_data 2_provision '{"id":111,"ip":"10.10.10.21"}'
state_layer_data() {
  local layer="$1" json="$2"
  local tmp="${INSTALL_STATE_FILE}.tmp"
  jq \
    --arg l "$layer" \
    --argjson d "$json" \
    '.layers[$l] = (.layers[$l] // {}) | .layers[$l].data = $d' \
    "$INSTALL_STATE_FILE" > "$tmp" && mv "$tmp" "$INSTALL_STATE_FILE"
}

# Record adapter selection — usage: state_adapter_set hypervisor <adapter-name>
state_adapter_set() {
  local kind="$1" name="$2"
  local tmp="${INSTALL_STATE_FILE}.tmp"
  jq \
    --arg k "$kind" \
    --arg n "$name" \
    '.adapters[$k] = $n' \
    "$INSTALL_STATE_FILE" > "$tmp" && mv "$tmp" "$INSTALL_STATE_FILE"
}

# Read selected adapter — usage: state_adapter_get hypervisor
state_adapter_get() {
  local kind="$1"
  jq -r ".adapters[\"$kind\"] // \"\"" "$INSTALL_STATE_FILE" 2>/dev/null || echo ""
}

# Diff state for resume — print which layers are pending/running/failed.
state_summary() {
  jq -r '
    .layers | to_entries | sort_by(.key) | .[] |
    "  " + .key + " : " + (.value.status // "pending")
  ' "$INSTALL_STATE_FILE" 2>/dev/null || true
}

# Layers that need to run when resuming.
state_pending_layers() {
  jq -r '
    .layers | to_entries | sort_by(.key) | .[] |
    select(.value.status != "done" and .value.status != "skipped") | .key
  ' "$INSTALL_STATE_FILE" 2>/dev/null || true
}
