#!/usr/bin/env bash
# =============================================================================
# preflight-services-check.sh
# =============================================================================
# Source-tree gate that runs BEFORE any bundle is built.
#
# Each function below catches a specific class of silent boot-time crash that
# Soldier C had to forensically diagnose on 2026-04-25 (~15 services were in a
# crash-restart loop with EMPTY pm2 stderr; every fix had to be source-side
# anyway). This script encodes "never again" guards so the next twice-daily
# fresh install fails LOUDLY at build time, not silently at boot time.
#
# Background — the failure modes detected here:
#
#   F1  SDK index transitively requires `typeorm` / `@nestjs/typeorm` even on
#       Mongoose-only consumers, causing `Cannot find module 'typeorm'` at
#       boot. Fix landed in zorbit-sdk-node/src/entity-crud/{service-factory,
#       entity-crud.module}.ts: lazy-require behind getter functions.
#       Guard: `check_sdk_lazy_typeorm_loading`
#       Guard: `check_sdk_lazy_nestjs_typeorm_loading`
#
#   F2  Source files that `import` a path containing `'../../seeds/'` (two
#       levels up). When tsc emits dist/<x>/file.js, the runtime require()
#       resolves OUTSIDE dist/, where the seed JS never lands.
#       Fix: move seeds/ into src/seeds/ so import is one level up.
#       Guard: `check_no_dotdot_seeds_imports`
#
#   F3  Services with non-TS asset directories (`entities/`, `seeds/`) that
#       must be present at runtime but are NOT copied by the Dockerfile.
#       Verified via the per-bundle Dockerfile.<bundle>.j2 templates.
#       Guard: `check_dockerfile_copies_runtime_assets`
#
#   F4  Code that reads `MONGODB_URI` instead of the platform-standard
#       `MONGO_URI`. Falls back to localhost:27017 → ECONNREFUSED on every
#       managed deploy.
#       Guard: `check_mongo_uri_env_var_name`
#
#   F5  Compiled `dist/main.js` missing for ANY service listed in the bundle
#       manifest. PM2 starts a non-existent file → silent crash loop.
#       Guard: `check_dist_main_present`
#
# Wired into build-all-bundles.sh — runs before package-bundle.sh for any
# bundle. Exit code 1 on the first failure. Each guard prints WHAT, WHERE,
# and HOW TO FIX so the next dev knows exactly what to change in source.
#
# Usage:
#   bash preflight-services-check.sh [<repo-root>]
#
# Default repo-root: /Users/s/workspace/zorbit/02_repos
# =============================================================================
set -euo pipefail

# Auto-detect 02_repos relative to this script — works on laptop AND inside
# dev-sandbox container. (qq) installer-improvement fix 2026-04-27.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"   # → 02_repos

REPO_ROOT="${1:-${DEFAULT_REPO_ROOT}}"
if [[ ! -d "${REPO_ROOT}" ]]; then
  echo "preflight: repo root not found: ${REPO_ROOT}" >&2
  exit 2
fi

FAIL_COUNT=0

# -------------------------------------------------------------------------
# Helper — collect candidate service repos under REPO_ROOT
# Filter: directories whose name matches zorbit-(pfs|app|ai|cor)-*
# -------------------------------------------------------------------------
list_service_repos() {
  find "${REPO_ROOT}" -maxdepth 1 -mindepth 1 -type d \
    \( -name 'zorbit-pfs-*' -o -name 'zorbit-app-*' \
       -o -name 'zorbit-ai-*' -o -name 'zorbit-cor-*' \
       -o -name 'sample-customer-service' \) \
    -print 2>/dev/null \
    | sort
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "preflight: FAIL [$1]: $2" >&2
  if [[ -n "${3:-}" ]]; then
    echo "preflight:   FIX: $3" >&2
  fi
}

# =========================================================================
# F1  SDK lazy-require guards
# =========================================================================
# zorbit-sdk-node/src/entity-crud/service-factory.ts must NOT contain an
# eager top-level `import { ... } from 'typeorm'` (only `import type`).
# Otherwise EVERY consumer is forced to install typeorm.
check_sdk_lazy_typeorm_loading() {
  local f="${REPO_ROOT}/zorbit-sdk-node/src/entity-crud/service-factory.ts"
  if [[ ! -f "$f" ]]; then
    return 0  # SDK not in this checkout — skip
  fi
  # Allow `import type { ... } from 'typeorm'` (type-only, erased by tsc).
  # Reject any other top-level `from 'typeorm'` line.
  if grep -E "^import\s+(\{|[A-Za-z])" "$f" | grep -v "import type" \
       | grep -q "from 'typeorm'"; then
    fail "F1-typeorm" \
      "${f} has an eager runtime import of 'typeorm'" \
      "Convert to lazy require: define getTypeOrmRuntime() that calls require('typeorm') inside, and use it where In/Like/Between/Not/MoreThanOrEqual/LessThanOrEqual are needed. See git history of service-factory.ts for the pattern."
  fi
}

# zorbit-sdk-node/src/entity-crud/entity-crud.module.ts must NOT have an
# eager top-level `import { ... } from '@nestjs/typeorm'`.
check_sdk_lazy_nestjs_typeorm_loading() {
  local f="${REPO_ROOT}/zorbit-sdk-node/src/entity-crud/entity-crud.module.ts"
  if [[ ! -f "$f" ]]; then
    return 0
  fi
  if grep -E "^import\s+(\{|[A-Za-z])" "$f" | grep -v "import type" \
       | grep -q "from '@nestjs/typeorm'"; then
    fail "F1-nestjs-typeorm" \
      "${f} has an eager runtime import of '@nestjs/typeorm'" \
      "Convert to lazy require: define getNestTypeOrm() that calls require('@nestjs/typeorm') inside, and use it where getRepositoryToken/TypeOrmModule are needed. See git history of entity-crud.module.ts for the pattern."
  fi
}

# =========================================================================
# F2  Service source must not use `../../seeds/...` imports
# =========================================================================
# Two-levels-up imports of seeds/ resolve outside dist/ at runtime.
# Move seeds/ into src/seeds/ and use one-level-up imports.
check_no_dotdot_seeds_imports() {
  local hits
  hits="$(grep -rEn "from\s+['\"]\\.\\./\\.\\./seeds/" \
            "${REPO_ROOT}"/zorbit-{pfs,app,ai,cor}-*/src/ 2>/dev/null \
            | grep -v node_modules || true)"
  if [[ -n "$hits" ]]; then
    while IFS= read -r line; do
      fail "F2-seeds-path" \
        "$line" \
        "Move seeds/ into src/seeds/ in this repo; change the import to '../seeds/<file>'. Two-levels-up imports of seeds/ resolve outside dist/ at runtime."
    done <<<"$hits"
  fi
}

# =========================================================================
# F3  Each repo with entities/*.entity.json or seeds/* must have those
# directories COPYed by the bundle Dockerfile template that ships it.
# =========================================================================
# We don't enumerate every Dockerfile/repo combination — instead we verify
# that for each repo that DOES have non-TS asset dirs, at least one of the
# pfs/apps/ai Dockerfile templates COPIES the asset path. Best-effort static
# check; a missing match fails the build.
check_dockerfile_copies_runtime_assets() {
  local templates_dir="${REPO_ROOT}/zorbit-cli/scripts/templates"
  if [[ ! -d "$templates_dir" ]]; then
    return 0  # cli not in this checkout
  fi
  local repos
  while IFS= read -r repo; do
    local repo_name
    repo_name="$(basename "$repo")"
    # Check for non-TS asset folders that the runtime needs
    for asset in entities seeds; do
      if [[ -d "$repo/$asset" ]] \
         && find "$repo/$asset" -mindepth 1 -maxdepth 1 \
              \( -name '*.json' -o -name '*.ts' -o -name '*.js' \) \
              | grep -q .; then
        # Asset dir is non-empty — check at least one template copies it
        if ! grep -RE "COPY\s+02_repos/${repo_name}/${asset}\b" \
             "$templates_dir" >/dev/null 2>&1; then
          fail "F3-asset-not-copied" \
            "${repo_name}/${asset}/ has runtime files but no Dockerfile template COPYs it" \
            "Add  COPY 02_repos/${repo_name}/${asset}  /app/${repo_name}/${asset}  to scripts/templates/Dockerfile.<bundle>.j2 (where <bundle> is the bundle that ships this service)."
        fi
      fi
    done
  done < <(list_service_repos)
}

# =========================================================================
# F4  Mongoose services should standardise on MONGO_URI (not MONGODB_URI)
# =========================================================================
# The platform ecosystem.config.js sets MONGO_URI. A service that ONLY reads
# MONGODB_URI falls through to its localhost default and crashes.
check_mongo_uri_env_var_name() {
  local hits
  # Match `config.get(...'MONGODB_URI'...)` or `process.env.MONGODB_URI`
  # but allow the file if it ALSO references MONGO_URI (fallback chain).
  while IFS= read -r f; do
    if grep -qE "MONGODB_URI" "$f"; then
      if ! grep -qE "MONGO_URI[^_]" "$f"; then
        fail "F4-mongo-uri" \
          "$f references MONGODB_URI without MONGO_URI fallback" \
          "Change to:  config.get('MONGO_URI') || config.get('MONGODB_URI') || '<localhost-default>'  (platform standard env var is MONGO_URI; MONGODB_URI is the legacy name)."
      fi
    fi
  done < <(grep -rEln "MONGODB_URI" \
              "${REPO_ROOT}"/zorbit-{pfs,app,ai,cor}-*/src/ 2>/dev/null \
              | grep -v node_modules || true)
}

# =========================================================================
# F5  Each repo MUST have dist/main.js after a build (or no build at all).
# =========================================================================
# This guard runs OPTIONALLY when --require-dist is passed; on a fresh
# checkout dist/ may legitimately be absent. The full bundle-build pipeline
# uses `npm run build` separately. We only flag the case where dist/ EXISTS
# but main.js is missing — a corrupted/partial build.
check_dist_main_present() {
  while IFS= read -r repo; do
    local repo_name
    repo_name="$(basename "$repo")"
    if [[ -d "$repo/dist" ]] && [[ ! -f "$repo/dist/main.js" ]]; then
      # Some services emit dist/src/main.js — accept that variant
      if [[ -f "$repo/dist/src/main.js" ]]; then
        continue
      fi
      # Vite/SPA repos emit dist/index.html + dist/assets/ instead of main.js.
      # Recognise by either index.html in dist/ or by package.json having a
      # `vite` script. (qq) installer-improvement fix 2026-04-27 — F5 was
      # firing on legitimately built SPA bundles.
      if [[ -f "$repo/dist/index.html" ]] || [[ -d "$repo/dist/assets" ]]; then
        continue
      fi
      if [[ -f "$repo/package.json" ]] && grep -qE '"build":\s*"vite' "$repo/package.json" 2>/dev/null; then
        # Vite SPA but dist/ is empty/partial — flag separately so it's
        # actionable, but don't claim missing main.js.
        fail "F5-spa-empty-dist" \
          "${repo_name}/dist/ exists but neither index.html nor assets/ found (vite build never completed)" \
          "Run \`npm run build\` in this repo. Vite emits dist/index.html + dist/assets/ for SPAs."
        continue
      fi
      fail "F5-no-main-js" \
        "${repo_name}/dist/ exists but neither dist/main.js nor dist/src/main.js was emitted" \
        "Run \`npm run build\` in this repo. Common causes: tsc emit error suppressed by a stale tsbuildinfo; rootDir/include misconfigured. Delete dist/ + tsconfig.build.tsbuildinfo and rebuild."
    fi
  done < <(list_service_repos)
}

# =========================================================================
# Run everything
# =========================================================================
echo "preflight: checking source tree at ${REPO_ROOT}"
check_sdk_lazy_typeorm_loading
check_sdk_lazy_nestjs_typeorm_loading
check_no_dotdot_seeds_imports
check_dockerfile_copies_runtime_assets
check_mongo_uri_env_var_name
check_dist_main_present

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo >&2
  echo "preflight: ${FAIL_COUNT} guard(s) failed — fix the issues above before building bundles." >&2
  echo "preflight: each guard exists because a previous fresh-install crashed silently on it." >&2
  exit 1
fi

echo "preflight: OK — all silent-fail guards passed."
exit 0
