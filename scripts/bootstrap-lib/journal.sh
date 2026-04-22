#!/usr/bin/env bash
# zorbit-cli/scripts/bootstrap-lib/journal.sh
# Install journal: append-only JSONL log of every state-change step so we
# can replay undo commands in reverse order if a deploy fails.
#
# Consumers:
#   - bootstrap-env.sh       -> journal_record ...      on each step
#   - bootstrap-env.sh       -> journal_rollback        on trap EXIT != 0
#   - bootstrap-env.sh       -> journal_rollback_last   on --rollback-last
#   - decommission.sh        -> journal_clear           on successful uninstall
#
# File layout:
#   /opt/zorbit-platform/<env>/install-journal.jsonl
#
# Entry schema (one JSON object per line):
#   {
#     "ts":    "2026-04-23T14:02:11Z",
#     "step":  "create_database",
#     "env":   "zorbit-dev",
#     "cmd":   "docker exec zs-pg psql -c 'CREATE DATABASE ...'",
#     "undo":  "docker exec zs-pg psql -c 'DROP DATABASE ...'",
#     "tags":  "database,postgres,dev",
#     "status":"ok"
#   }
#
# Spec version: 1.0 (2026-04-23)
# ---------------------------------------------------------------------------

# Directory the journal lives in. Resolved per-env by the caller.
: "${JOURNAL_ROOT:=/opt/zorbit-platform}"

journal_path() {
  # journal_path <env>
  local env_name="$1"
  printf '%s/%s/install-journal.jsonl' "${JOURNAL_ROOT}" "${env_name}"
}

journal_init() {
  # journal_init <env>
  # Creates the journal directory + empty file if absent. Safe to call repeatedly.
  local env_name="$1"
  local path
  path="$(journal_path "${env_name}")"
  local dir
  dir="$(dirname "${path}")"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "DRY: would ensure journal at ${path}"
    return 0
  fi
  mkdir -p "${dir}" 2>/dev/null || true
  [[ -f "${path}" ]] || : > "${path}"
}

journal_record() {
  # journal_record <env> <step> <cmd> <undo> [tags]
  # Appends a new entry. All arguments are strings, not shell arrays.
  local env_name="$1"; local step="$2"; local cmd="$3"; local undo="$4"
  local tags="${5:-}"
  local path
  path="$(journal_path "${env_name}")"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf '%s[JRNL ]%s %s step=%s\n' "${C_YEL:-}" "${C_RESET:-}" "$(date +'%Y-%m-%d %H:%M:%S')" "${step}"
    return 0
  fi

  [[ -f "${path}" ]] || journal_init "${env_name}"

  python3 - "${path}" "${env_name}" "${step}" "${cmd}" "${undo}" "${tags}" <<'PY'
import sys, json, datetime, os
path, env_name, step, cmd, undo, tags = sys.argv[1:7]
entry = {
    "ts":     datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "step":   step,
    "env":    env_name,
    "cmd":    cmd,
    "undo":   undo,
    "tags":   tags,
    "status": "ok",
}
with open(path, "a") as f:
    f.write(json.dumps(entry) + "\n")
PY
}

journal_count() {
  # journal_count <env>  -> prints number of entries to stdout (0 if missing)
  local env_name="$1"
  local path
  path="$(journal_path "${env_name}")"
  [[ -f "${path}" ]] || { echo 0; return 0; }
  wc -l <"${path}" | tr -d ' '
}

journal_list_undos() {
  # journal_list_undos <env>
  # Print a human-readable list of undo commands in reverse order (LIFO).
  local env_name="$1"
  local path
  path="$(journal_path "${env_name}")"
  if [[ ! -f "${path}" ]]; then
    log_warn "No journal found at ${path}"
    return 1
  fi
  python3 - "${path}" <<'PY'
import sys, json
path = sys.argv[1]
entries = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            entries.append(json.loads(line))
        except Exception:
            pass
if not entries:
    print("(journal is empty)")
    raise SystemExit(0)
for i, e in enumerate(reversed(entries), 1):
    print(f"  {i:2d}. [{e.get('step')}] undo: {e.get('undo') or '(no-op)'}")
PY
}

journal_rollback() {
  # journal_rollback <env>
  # Execute every undo in reverse order. Best-effort: log + continue on failure.
  # Exit code: 0 if all undos succeeded, 4 if any failed.
  local env_name="$1"
  local path
  path="$(journal_path "${env_name}")"
  if [[ ! -f "${path}" ]]; then
    log_warn "No journal to rollback at ${path}"
    return 0
  fi

  local tmp_undos
  tmp_undos="$(mktemp -t zorbit-rollback-XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp_undos}'" RETURN

  python3 - "${path}" "${tmp_undos}" <<'PY'
import sys, json
path, out = sys.argv[1:3]
entries = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: entries.append(json.loads(line))
        except Exception: pass
with open(out, "w") as f:
    for e in reversed(entries):
        undo = (e.get("undo") or "").strip()
        step = e.get("step") or "?"
        if not undo:
            f.write(f"__NOOP__|{step}|(no undo registered)\n")
            continue
        f.write(f"__UNDO__|{step}|{undo}\n")
PY

  local failures=0
  local total=0
  while IFS='|' read -r kind step payload; do
    total=$((total + 1))
    case "${kind}" in
      __NOOP__)
        log_info "  skip [${step}] ${payload}"
        ;;
      __UNDO__)
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
          log_info "  DRY undo [${step}]: ${payload}"
        else
          log_info "  undo [${step}]: ${payload}"
          if ! bash -c "${payload}" 2>&1 | sed 's/^/      /'; then
            log_warn "     undo step failed (continuing): ${step}"
            failures=$((failures + 1))
          fi
        fi
        ;;
    esac
  done <"${tmp_undos}"

  log_info "Rollback complete: ${total} entries, ${failures} failures"
  if [[ ${failures} -gt 0 ]]; then
    return 4
  fi
  return 0
}

journal_rollback_auto_trap() {
  # Register this function as a trap handler for unclean exit.
  # Usage (inside bootstrap-env.sh after ENV_NAME is set):
  #   trap 'journal_rollback_auto_trap "${ENV_NAME}" $?' EXIT
  local env_name="$1"; local exit_code="${2:-0}"
  [[ "${exit_code}" -eq 0 ]] && return 0
  [[ "${ZORBIT_SKIP_AUTO_ROLLBACK:-false}" == "true" ]] && {
    log_warn "Auto-rollback skipped (ZORBIT_SKIP_AUTO_ROLLBACK=true). Journal retained."
    return 0
  }
  log_warn "Bootstrap exited with code ${exit_code} — initiating auto-rollback"
  journal_rollback "${env_name}" || true
}

journal_archive() {
  # journal_archive <env>
  # Rename the journal file to install-journal.<timestamp>.jsonl on successful
  # install so we don't replay old entries on a re-install. Keeps an archive
  # trail for forensics.
  local env_name="$1"
  local path
  path="$(journal_path "${env_name}")"
  [[ -f "${path}" ]] || return 0
  [[ "${DRY_RUN:-false}" == "true" ]] && { log_info "DRY: would archive ${path}"; return 0; }
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  mv "${path}" "${path%.jsonl}.${ts}.jsonl"
  log_ok "Journal archived: ${path%.jsonl}.${ts}.jsonl"
}

journal_clear() {
  # journal_clear <env>
  # Wipe the active journal (called post-decommission).
  local env_name="$1"
  local path
  path="$(journal_path "${env_name}")"
  [[ "${DRY_RUN:-false}" == "true" ]] && { log_info "DRY: would remove ${path}"; return 0; }
  [[ -f "${path}" ]] && rm -f "${path}"
}
