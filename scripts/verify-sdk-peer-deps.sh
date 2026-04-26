#!/usr/bin/env bash
# =============================================================================
# verify-sdk-peer-deps.sh — post-deploy SDK peer-dep resolution gate
# =============================================================================
# Runs INSIDE a ze-* container (or any host with /app/<svc>/ + node binary).
# For every consumer service in /app/zorbit-* with a package.json, verifies
# that the CRITICAL transitive deps (axios, @nestjs/typeorm, mongoose, ...)
# resolve from the consumer's perspective.
#
# Output: tab-separated table to stdout + a JSON summary to stderr.
#
# Exit codes:
#   0 = every consumer can resolve every critical dep
#   1 = at least one consumer is missing at least one critical dep
#   2 = invocation error (no /app, no node, etc.)
#
# Use:
#   - As fresh-install.sh L4.5 gate (run inside each ze-* container)
#   - As ad-hoc smoke test after an SDK fleet upgrade
#   - As a soldier (s) precondition before declaring "Batch 2 done"
# =============================================================================
set -uo pipefail

APP_ROOT="${1:-/app}"

[[ -d "$APP_ROOT" ]] || { echo "verify-sdk-peer-deps: $APP_ROOT not a directory" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "verify-sdk-peer-deps: node not in PATH" >&2; exit 2; }

# Critical peer-deps — must resolve for every consumer that imports the SDK.
CRITICAL_DEPS=(
  axios
  '@nestjs/typeorm'
  mongoose
  kafkajs
  rxjs
)

resolve_pkg() {
  local pkg="$1" svc_dir="$2"
  # Match the runtime resolution that PM2 uses (every ecosystem entry sets
  # NODE_OPTIONS=--preserve-symlinks). With that flag set, Node does NOT walk
  # the symlink real path, so packages are resolved from the consumer's own
  # node_modules tree (which is where the prune script intentionally pushes
  # them). Verifier must match this behaviour or it generates false positives.
  NODE_OPTIONS="--preserve-symlinks" node -e "
    try {
      require.resolve('${pkg}/package.json', { paths: ['${svc_dir}'] });
      process.exit(0);
    } catch (e) {
      try {
        require.resolve('${pkg}', { paths: ['${svc_dir}'] });
        process.exit(0);
      } catch (e2) {
        process.exit(1);
      }
    }
  " 2>/dev/null
}

TOTAL=0
OK=0
FAIL=0
FAILED_LIST=()

printf 'service\tdep\tstatus\n'
for svc_dir in "${APP_ROOT}"/zorbit-*; do
  [[ -d "$svc_dir" ]] || continue
  [[ -f "${svc_dir}/package.json" ]] || continue
  # Skip the SDK itself (it's a library, not a consumer) and any backups.
  case "$(basename "$svc_dir")" in
    zorbit-sdk-node|zorbit-sdk-react|zorbit-cli|zorbit-core) continue ;;
    *.bak.*|*.bak) continue ;;
  esac
  # Only check consumers that depend on @zorbit-platform/sdk-node
  if ! grep -q '@zorbit-platform/sdk-node' "${svc_dir}/package.json" 2>/dev/null; then
    continue
  fi
  svc=$(basename "$svc_dir")
  for dep in "${CRITICAL_DEPS[@]}"; do
    TOTAL=$((TOTAL + 1))
    if resolve_pkg "$dep" "$svc_dir"; then
      OK=$((OK + 1))
      printf '%s\t%s\tOK\n' "$svc" "$dep"
    else
      FAIL=$((FAIL + 1))
      FAILED_LIST+=("${svc}::${dep}")
      printf '%s\t%s\tMISSING\n' "$svc" "$dep"
    fi
  done
done

# JSON summary on stderr (so stdout stays parseable as TSV)
{
  printf '\n{\n'
  printf '  "total": %d,\n' "$TOTAL"
  printf '  "ok": %d,\n' "$OK"
  printf '  "fail": %d,\n' "$FAIL"
  printf '  "failed": ['
  if [[ ${#FAILED_LIST[@]} -gt 0 ]]; then
    printf '"%s"' "${FAILED_LIST[0]}"
    for i in "${FAILED_LIST[@]:1}"; do printf ',"%s"' "$i"; done
  fi
  printf ']\n'
  printf '}\n'
} >&2

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
