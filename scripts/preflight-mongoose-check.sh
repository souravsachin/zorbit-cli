#!/usr/bin/env bash
# =============================================================================
# preflight-mongoose-check.sh
# =============================================================================
# Static check: scans all *.schema.ts files under the given source roots and
# fails if any @Prop(...) decorator is missing an explicit `type:` while the
# associated TypeScript field type is one that NestJS Mongoose CANNOT infer:
#
#   - union types containing `|` (e.g. `string | null`, literal unions)
#   - `any`, `unknown`, `object`
#   - `Record<...>`
#   - inline object literal `{ ... }`
#
# Background
# ----------
# These produce a runtime crash on service boot:
#
#   CannotDetermineTypeError: Cannot determine a type for the "<Class>.<field>"
#   field (union/intersection/ambiguous type was used). Make sure your property
#   is decorated with a "@Prop({ type: TYPE_HERE })" decorator.
#
# Several Zorbit services regressed because of this on 2026-04-25 — Soldier B
# patched 6 fields across 3 services. This preflight wires a build-time gate so
# the next install (clean repo clone) cannot regress.
#
# Exit codes
# ----------
#   0 — no problematic @Prop() decorators found
#   1 — at least one offending field; details printed to stderr
#   2 — usage error
#
# Usage
# -----
#   bash preflight-mongoose-check.sh [<root1> <root2> ...]
#
# If no roots are given, defaults to:
#   /Users/s/workspace/zorbit/02_repos
#
# Wired into build-all-bundles.sh — runs before any bundle is packaged.
# =============================================================================
set -euo pipefail

ROOTS=("$@")
if [[ ${#ROOTS[@]} -eq 0 ]]; then
  ROOTS=("/Users/s/workspace/zorbit/02_repos")
fi

# Collect schema files
SCHEMA_FILES=()
for r in "${ROOTS[@]}"; do
  if [[ ! -d "$r" ]]; then
    echo "preflight: root not found: $r" >&2
    exit 2
  fi
  while IFS= read -r f; do
    SCHEMA_FILES+=("$f")
  done < <(find "$r" \
              -path '*/node_modules' -prune -o \
              -path '*/dist' -prune -o \
              -name '*.schema.ts' -print 2>/dev/null)
done

if [[ ${#SCHEMA_FILES[@]} -eq 0 ]]; then
  echo "preflight: no *.schema.ts files found under: ${ROOTS[*]}"
  exit 0
fi

echo "preflight: scanning ${#SCHEMA_FILES[@]} schema files for ambiguous @Prop() decorators..."

# Use embedded python — every dev box and CI has python3.
PY_RESULT="$(python3 - "${SCHEMA_FILES[@]}" <<'PYEOF'
import re
import sys
from pathlib import Path

files = sys.argv[1:]

# Match @Prop( ... ) with up to 1 nested paren level, then field-name : type ;
# Captures multi-line @Prop blocks (DOTALL on args).
PROP_RE = re.compile(
    r"@Prop\((?P<args>(?:[^()]|\([^()]*\))*)\)\s*\n\s*(?P<field>\w+)\??!?\s*:\s*(?P<type>[^;=\n{][^;=\n]*?)\s*[;=\n]",
    re.DOTALL,
)

issues = []
for f in files:
    p = Path(f)
    if not p.exists():
        continue
    try:
        text = p.read_text()
    except Exception as e:
        print(f"WARN: {f}: {e}", file=sys.stderr)
        continue
    for m in PROP_RE.finditer(text):
        args = m.group("args")
        # Skip if explicit `type:` is set on the @Prop options
        if re.search(r"\btype\s*:", args):
            continue
        ts_type = m.group("type").strip()
        reason = None
        if "|" in ts_type:
            reason = "union"
        elif re.search(r"\b(any|unknown|object)\b", ts_type):
            reason = "any/unknown/object"
        elif re.search(r"\bRecord\s*<", ts_type):
            reason = "Record<>"
        if reason:
            line = text[: m.start()].count("\n") + 1
            issues.append((str(p), line, m.group("field"), ts_type, reason))

for f, line, field, t, why in issues:
    print(f"{f}:{line}: field='{field}' ts_type='{t}' [{why}]")

print(f"__TOTAL__={len(issues)}")
PYEOF
)" || {
  echo "preflight: scanner crashed" >&2
  exit 2
}

{ echo "$PY_RESULT" | grep -v '^__TOTAL__=' || true; } >&2
TOTAL_LINE="$(echo "$PY_RESULT" | grep '^__TOTAL__=' || true)"
TOTAL="${TOTAL_LINE#__TOTAL__=}"

if [[ -z "$TOTAL" ]]; then
  echo "preflight: scanner produced no total — assuming failure" >&2
  exit 2
fi

if [[ "$TOTAL" -gt 0 ]]; then
  echo >&2
  echo "preflight: FAIL — $TOTAL @Prop() decorator(s) missing explicit \`type:\`" >&2
  echo "preflight: fix each one above by adding \`type: String|Number|Boolean|Date|SchemaTypes.Mixed\`" >&2
  echo "preflight: example:  @Prop({ type: String, default: null })  foo!: string | null;" >&2
  exit 1
fi

echo "preflight: OK — 0 ambiguous @Prop() decorators in ${#SCHEMA_FILES[@]} schema files"
exit 0
