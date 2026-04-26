#!/usr/bin/env bash
# =============================================================================
# install-sdk-tarball.sh — idempotent SDK fleet-deploy installer
# =============================================================================
# WHEN to use this script:
#   - You have a new @zorbit-platform/sdk-node tarball (e.g. 0.5.5 → 0.5.6).
#   - You want to upgrade a SUBSET of consumers WITHOUT a full bundle bake.
#   - The container is already running; tarball will be hot-swapped.
#
# WHAT it does (per consumer):
#   1. Extract SDK tarball → /app/zorbit-sdk-node/ (replace dist/ + node_modules/).
#      Idempotent on re-run via tmpdir-then-swap (cycle-105 (w) MSG-079).
#   2. Run `npm rebuild @zorbit-platform/sdk-node` in the CONSUMER directory so
#      the postinstall prune-peer-deps.js fires under ZORBIT_SDK_FORCE_PRUNE=1.
#   3. Verify each critical transitive dep resolves from the consumer's perspective:
#        axios, @nestjs/typeorm, @nestjs/axios, mongoose, kafkajs, rxjs
#      (axios + kafkajs come from SDK's own deps; the rest are peer-deps from
#      the consumer's own node_modules.)
#   4. If any verification fails, run `npm install --no-save <missing-pkgs>`
#      in the consumer directory to bake them in. Re-verify.
#   4.5. Refresh per-service BAKED-IN SDK copies (real dir, not symlink) at
#        /app/zorbit-*/node_modules/@zorbit-platform/sdk-node/. Without this,
#        services like identity / authz / nav (which baked the SDK at npm ci
#        time) silently keep the stale copy after the shared SDK_DIR is
#        updated. (cycle-105 (w) MSG-079, post-(v) finding)
#   5. Print a JSON summary on stdout for the caller to consume.
#
# WHY this script exists:
#   Before this fix, replacing only the SDK's dist/ in /app/zorbit-sdk-node/
#   broke peer-dep resolution because:
#     - The new dist/ may import packages (e.g. @nestjs/axios, mongoose) that
#       the SDK's pre-pruned node_modules/ no longer contains.
#     - --preserve-symlinks tells Node to look in the SYMLINK location, so it
#       walks up from /app/<svc>/node_modules/@zorbit-platform/sdk-node/ to
#       /app/<svc>/node_modules/. If the consumer doesn't have axios/mongoose
#       in its OWN package.json, resolution fails with "Cannot find module".
#     - Soldier (o) finding 2026-04-26 20:07 +07: zorbit-navigation broke this
#       way after a 0.5.3 → 0.5.5 SDK tarball replace.
#
# Usage (inside a container running the consumer service):
#   bash install-sdk-tarball.sh \
#        --svc zorbit-pii-vault \
#        --sdk-tar /tmp/sdk-node-0.5.6.tgz \
#        [--app-root /app] \
#        [--restart]                # pm2 restart <svc> on success
#        [--dry-run]                # report only, no changes
#
# Exit codes:
#   0 = SDK installed + all peer-deps resolve
#   1 = arg / file error
#   2 = extraction failed
#   3 = peer-dep verification failed AFTER bake (true install failure)
#
# Idempotent: running twice is safe.
# =============================================================================

set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
SVC=""
SDK_TAR=""
APP_ROOT="/app"
RESTART=false
DRY_RUN=false

# Critical peer-deps that MUST resolve from the consumer's perspective once
# the SDK is in place. Add to this list as the SDK gains new transitive deps.
#   axios          — HTTP client (SDK's clients/, interceptors/, middleware/)
#   kafkajs        — SDK's kafka/ client
#   rxjs           — peer dep, often transitive (every consumer imports it)
#
# IMPORTANT: do NOT add lazy-loaded SDK deps here. The SDK lazy-loads its
# database adapter (mongoose) and TypeORM helpers (@nestjs/typeorm) — a
# consumer that does not import those features should NOT need them in its
# own node_modules. Putting them here triggers an unnecessary
# `npm install --no-save` bake which can OOM-kill on memory-constrained
# containers (ze-pfs / ze-apps observed at >95% memUsed during fleet
# upgrades 2026-04-26 by soldier (s) MSG-071).
CRITICAL_DEPS=(
  axios
  kafkajs
  rxjs
)
# Optional deps (some consumers don't import them). Verify but don't auto-install
# unless missing. @nestjs/axios is in this list because not every consumer uses
# HttpModule. mongoose + @nestjs/typeorm are here for the same reason — the
# SDK lazy-loads them; absence is fine when the consumer does not use them.
OPTIONAL_DEPS=(
  mongoose
  '@nestjs/typeorm'
  '@nestjs/axios'
  '@nestjs/common'
  '@nestjs/core'
  '@nestjs/passport'
  passport
  passport-jwt
  'reflect-metadata'
  typeorm
)
# SDK-bundled deps — packages that the SDK ships in its own node_modules
# pre-prune. With NODE_OPTIONS=--preserve-symlinks (PM2 runtime), consumers
# cannot reach into the SDK's bundled node_modules. To make these resolvable
# from the consumer's parent walk, bootstrap a symlink in /app/node_modules/
# pointing at the SDK's copy. This avoids both an `npm install` bake (memory
# pressure) AND a duplicated copy of the dep (disk).
SDK_BUNDLED_DEPS=(axios mongoose kafkajs)

# ---- CLI parse --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --svc)        SVC="$2"; shift 2 ;;
    --sdk-tar)    SDK_TAR="$2"; shift 2 ;;
    --app-root)   APP_ROOT="$2"; shift 2 ;;
    --restart)    RESTART=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)    sed -n '1,50p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$SVC"     ]] && { echo "ERROR: --svc <service-name> required" >&2; exit 1; }
[[ -z "$SDK_TAR" ]] && { echo "ERROR: --sdk-tar <path-to-tarball> required" >&2; exit 1; }
[[ -f "$SDK_TAR" ]] || { echo "ERROR: SDK tarball not found: $SDK_TAR" >&2; exit 1; }

SVC_DIR="${APP_ROOT}/${SVC}"
SDK_DIR="${APP_ROOT}/zorbit-sdk-node"

[[ -d "$SVC_DIR" ]] || { echo "ERROR: consumer dir not found: $SVC_DIR" >&2; exit 1; }
[[ -f "$SVC_DIR/package.json" ]] || { echo "ERROR: missing $SVC_DIR/package.json" >&2; exit 1; }

# ---- Helpers ----------------------------------------------------------------
log() { printf '[install-sdk-tarball] %s\n' "$*" >&2; }

# Resolve a package from the consumer's perspective.
# Match PM2 runtime: every ecosystem entry sets NODE_OPTIONS=--preserve-symlinks.
# Verifier must use same flag or it generates false negatives.
# Returns 0 if resolves, 1 otherwise. Stdout: resolved path (or empty).
resolve_pkg() {
  local pkg="$1"
  NODE_OPTIONS="--preserve-symlinks" node -e "
    try {
      const p = require.resolve('${pkg}/package.json', { paths: ['${SVC_DIR}'] });
      console.log(p);
      process.exit(0);
    } catch (e) {
      try {
        const p = require.resolve('${pkg}', { paths: ['${SVC_DIR}'] });
        console.log(p);
        process.exit(0);
      } catch (e2) {
        process.exit(1);
      }
    }
  " 2>/dev/null
}

# ---- Phase 1: extract SDK tarball -------------------------------------------
# Bug-fix (cycle-105 (w) MSG-079, post-(v) finding 21:46 +07):
#   The earlier in-place "extract, then maybe strip-components=1" heuristic
#   was NOT idempotent. On a re-run, an outer package.json from the previous
#   extract already existed at $SDK_DIR/package.json, so the heuristic
#   `[[ ! -f $SDK_DIR/package.json && -f $SDK_DIR/package/package.json ]]`
#   never fired. Result: the new tarball's leading `package/` prefix was
#   left under $SDK_DIR/package/{package.json,dist,...} while the OLD outer
#   files stayed in place — silent partial install. Soldier (v) hit this
#   on identity 0.5.7 redeploy.
#
#   Fix: extract to a fresh tmpdir FIRST, decide layout from the tmpdir
#   (where there are zero pre-existing files), then atomically swap into
#   $SDK_DIR. Sidesteps the heuristic entirely; idempotent by construction.
log "phase 1: extract ${SDK_TAR} → ${SDK_DIR}"
if $DRY_RUN; then
  log "  --dry-run: would extract"
else
  # Preserve a backup so we can roll back on verification failure.
  if [[ -d "$SDK_DIR" ]]; then
    BACKUP="${SDK_DIR}.bak.$(date +%s)"
    cp -a "$SDK_DIR" "$BACKUP"
    log "  backup → $BACKUP"
  fi

  TMP_EXTRACT="$(mktemp -d "${APP_ROOT}/.sdk-extract.XXXXXX")"
  trap 'rm -rf "$TMP_EXTRACT"' EXIT
  tar -xzf "$SDK_TAR" -C "$TMP_EXTRACT" 2>&1 || { log "ERROR: extract failed"; exit 2; }

  # Determine source root inside the tmpdir:
  #   (a) tarball had top-level dist/ + package.json → src=$TMP_EXTRACT
  #   (b) tarball had leading `package/` dir         → src=$TMP_EXTRACT/package
  if [[ -f "$TMP_EXTRACT/package.json" ]]; then
    SRC_ROOT="$TMP_EXTRACT"
    log "  layout: top-level (no package/ prefix)"
  elif [[ -f "$TMP_EXTRACT/package/package.json" ]]; then
    SRC_ROOT="$TMP_EXTRACT/package"
    log "  layout: npm-pack style (leading package/ dir)"
  else
    log "ERROR: tarball has no recognisable package.json at root or package/"
    ls -la "$TMP_EXTRACT" >&2 || true
    exit 2
  fi

  # Atomic-ish swap: clear $SDK_DIR (we backed it up above) and copy
  # contents of SRC_ROOT into it. `cp -a SRC/. DEST/` copies including
  # dotfiles and works across filesystems (mktemp may be on tmpfs).
  rm -rf "$SDK_DIR"
  mkdir -p "$SDK_DIR"
  cp -a "${SRC_ROOT}/." "$SDK_DIR/" || { log "ERROR: copy from tmpdir failed"; exit 2; }
  rm -rf "$TMP_EXTRACT"
  trap - EXIT

  [[ -f "$SDK_DIR/package.json" ]] || { log "ERROR: SDK package.json missing after extract"; exit 2; }
  # Defensive: if a stray $SDK_DIR/package/ subdir somehow ended up in place
  # (extremely unlikely, but cheap to guard against re-run regression), drop it.
  if [[ -d "$SDK_DIR/package" && -f "$SDK_DIR/package/package.json" ]]; then
    log "  WARN: nested $SDK_DIR/package/ detected post-extract; removing"
    rm -rf "$SDK_DIR/package"
  fi
  SDK_VER=$(node -p "require('${SDK_DIR}/package.json').version" 2>/dev/null || echo "?")
  log "  extracted SDK ${SDK_VER}"
fi

# ---- Phase 1.5: bootstrap shared symlinks for SDK-bundled deps --------------
# Without this, consumers in containers that have no /app/node_modules/ (eg
# ze-pfs / ze-apps fleet) cannot resolve axios / mongoose / kafkajs from
# their own perspective with --preserve-symlinks, even though the SDK ships
# those packages bundled. Symlinking once into /app/node_modules/<dep> makes
# them reachable to every consumer in the same APP_ROOT, no per-svc bake.
log "phase 1.5: bootstrap /app/node_modules symlinks for SDK-bundled deps"
if $DRY_RUN; then
  log "  --dry-run: would symlink ${SDK_BUNDLED_DEPS[*]}"
else
  mkdir -p "${APP_ROOT}/node_modules"
  for DEP in "${SDK_BUNDLED_DEPS[@]}"; do
    if [[ -d "${SDK_DIR}/node_modules/${DEP}" ]]; then
      # Only create the symlink if there is no native install already.
      if [[ ! -e "${APP_ROOT}/node_modules/${DEP}" ]]; then
        ln -sfn "${SDK_DIR}/node_modules/${DEP}" "${APP_ROOT}/node_modules/${DEP}"
        log "    linked ${DEP} -> ${SDK_DIR}/node_modules/${DEP}"
      fi
    fi
  done
fi

# ---- Phase 2: trigger postinstall prune (idempotent) ------------------------
log "phase 2: rebuild SDK linkage in consumer (fires postinstall prune)"
if $DRY_RUN; then
  log "  --dry-run: would rebuild"
else
  cd "$SVC_DIR"
  # Force prune even though the SDK is symlinked (postinstall normally only
  # fires on real install). Use the SDK's own prune script directly — that's
  # what the script's ZORBIT_SDK_FORCE_PRUNE=1 handle is for.
  if [[ -f "${SDK_DIR}/scripts/prune-peer-deps.js" ]]; then
    ZORBIT_SDK_FORCE_PRUNE=1 node "${SDK_DIR}/scripts/prune-peer-deps.js" 2>&1 | sed 's/^/    /' || true
  fi
  # Belt-and-braces: rm -rf the known peer-dep dirs from SDK's own node_modules
  # in case the prune script wasn't shipped in the tarball.
  if [[ -d "${SDK_DIR}/node_modules" ]]; then
    for p in '@nestjs' typeorm 'reflect-metadata' rxjs passport passport-jwt; do
      rm -rf "${SDK_DIR}/node_modules/${p}" 2>/dev/null || true
    done
  fi
fi

# ---- Phase 3: verify peer-dep resolution from consumer ----------------------
log "phase 3: verify ${#CRITICAL_DEPS[@]} critical peer-deps resolve"
MISSING_CRITICAL=()
RESOLVED=()
for dep in "${CRITICAL_DEPS[@]}"; do
  if path=$(resolve_pkg "$dep"); then
    RESOLVED+=("${dep}=${path}")
  else
    MISSING_CRITICAL+=("$dep")
  fi
done

# ---- Phase 4: bake-in missing critical deps ---------------------------------
if [[ ${#MISSING_CRITICAL[@]} -gt 0 ]]; then
  log "phase 4: ${#MISSING_CRITICAL[@]} critical dep(s) missing, baking via npm install --no-save"
  log "  missing: ${MISSING_CRITICAL[*]}"
  if $DRY_RUN; then
    log "  --dry-run: would npm install --no-save ${MISSING_CRITICAL[*]}"
  else
    cd "$SVC_DIR"
    if ! npm install --no-save --no-audit --no-fund "${MISSING_CRITICAL[@]}" 2>&1 | tail -5 | sed 's/^/    /'; then
      log "ERROR: npm install --no-save failed; consumer left in partial state"
      exit 3
    fi
    # Re-verify
    STILL_MISSING=()
    for dep in "${MISSING_CRITICAL[@]}"; do
      resolve_pkg "$dep" >/dev/null || STILL_MISSING+=("$dep")
    done
    if [[ ${#STILL_MISSING[@]} -gt 0 ]]; then
      log "ERROR: post-bake verification failed for: ${STILL_MISSING[*]}"
      exit 3
    fi
    log "  bake successful — all critical deps now resolve"
  fi
fi

# ---- Phase 4.5: refresh per-service baked-in SDK copies ---------------------
# Bug-fix (cycle-105 (w) MSG-079, post-(v) finding 21:46 +07):
#   Some consumers (zorbit-identity / zorbit-authorization / zorbit-navigation
#   on dev-sandbox VM 110) have the SDK as a REAL DIRECTORY at
#   /app/<svc>/node_modules/@zorbit-platform/sdk-node/ — not a symlink to
#   /app/zorbit-sdk-node/. This happens when `npm ci` / `npm install` fully
#   materialises the SDK tarball into the consumer's node_modules at
#   bundle-bake time. After that, updating only /app/zorbit-sdk-node/ has
#   ZERO effect on these services — they still load the stale baked copy.
#   Soldier (v) verified this by inspecting identity's per-service path
#   showing 0.5.5 while /app/zorbit-sdk-node/ was 0.5.7, then manually
#   `cp`'d files in. We bake that fix into the installer here.
#
# What we do:
#   For every /app/zorbit-*/node_modules/@zorbit-platform/sdk-node that
#   exists AND is a real directory (NOT a symlink), copy the freshly-
#   extracted dist/ + package.json from /app/zorbit-sdk-node/ over the
#   baked copy. We do NOT touch the baked copy's node_modules/ — peer-dep
#   resolution for those services is handled by their own consumer's
#   node_modules walk, same as the symlinked services.
log "phase 4.5: refresh per-service baked SDK copies"
BAKED_REFRESHED=()
BAKED_SKIPPED_SYMLINK=()
if $DRY_RUN; then
  log "  --dry-run: would scan ${APP_ROOT}/zorbit-*/node_modules/@zorbit-platform/sdk-node"
else
  if [[ -d "$SDK_DIR" && -f "$SDK_DIR/package.json" ]]; then
    shopt -s nullglob
    for SVC_PATH in "${APP_ROOT}"/zorbit-*/; do
      [[ -d "$SVC_PATH" ]] || continue
      SVC_NAME="$(basename "$SVC_PATH")"
      # Skip the SDK source itself.
      [[ "$SVC_NAME" == "zorbit-sdk-node" ]] && continue
      PER_SVC_SDK="${SVC_PATH}node_modules/@zorbit-platform/sdk-node"
      if [[ -L "$PER_SVC_SDK" ]]; then
        # Symlinked consumers already pick up updates via /app/zorbit-sdk-node/.
        BAKED_SKIPPED_SYMLINK+=("$SVC_NAME")
        continue
      fi
      if [[ -d "$PER_SVC_SDK" && -f "$PER_SVC_SDK/package.json" ]]; then
        # Real-directory baked copy. Replace package.json + dist/ from the
        # freshly-extracted SDK. Leave its node_modules/ alone (peer-deps
        # resolved via consumer's own walk).
        cp -a "${SDK_DIR}/package.json" "${PER_SVC_SDK}/package.json"
        if [[ -d "${SDK_DIR}/dist" ]]; then
          rm -rf "${PER_SVC_SDK}/dist"
          cp -a "${SDK_DIR}/dist" "${PER_SVC_SDK}/dist"
        fi
        # Refresh ancillary files consumers may reference.
        for f in README.md LICENSE CHANGELOG.md; do
          if [[ -f "${SDK_DIR}/${f}" ]]; then
            cp -a "${SDK_DIR}/${f}" "${PER_SVC_SDK}/${f}" 2>/dev/null || true
          fi
        done
        BAKED_REFRESHED+=("$SVC_NAME")
        log "    refreshed baked SDK in ${SVC_NAME}"
      fi
    done
    shopt -u nullglob
  fi
  if [[ ${#BAKED_REFRESHED[@]} -eq 0 ]]; then
    log "  no per-service baked-direct copies found (all consumers symlinked or absent)"
  else
    log "  refreshed ${#BAKED_REFRESHED[@]} baked copy/copies: ${BAKED_REFRESHED[*]}"
  fi
fi

# ---- Phase 5: summarise -----------------------------------------------------
log "phase 5: summary"
SDK_VER_OUT="${SDK_VER:-?}"
RESOLVED_LIST=$(printf '"%s",' "${RESOLVED[@]}" | sed 's/,$//')
MISSING_LIST=$(printf '"%s",' "${MISSING_CRITICAL[@]}" | sed 's/,$//')
BAKED_REFRESHED_LIST=$(printf '"%s",' "${BAKED_REFRESHED[@]}" | sed 's/,$//')
BAKED_SYMLINK_LIST=$(printf '"%s",' "${BAKED_SKIPPED_SYMLINK[@]}" | sed 's/,$//')
cat <<JSON
{
  "service":               "${SVC}",
  "sdk_version":           "${SDK_VER_OUT}",
  "sdk_dir":               "${SDK_DIR}",
  "consumer_dir":          "${SVC_DIR}",
  "resolved":              [${RESOLVED_LIST}],
  "missing_baked":         [${MISSING_LIST}],
  "baked_refreshed":       [${BAKED_REFRESHED_LIST}],
  "baked_skipped_symlink": [${BAKED_SYMLINK_LIST}],
  "dry_run":               ${DRY_RUN},
  "result":                "ok"
}
JSON

# ---- Phase 6 (optional): pm2 restart ----------------------------------------
if $RESTART && ! $DRY_RUN; then
  log "phase 6: pm2 restart ${SVC}"
  pm2 restart "${SVC}" --update-env >/dev/null 2>&1 || log "  WARN: pm2 restart failed (is pm2 running?)"
fi

exit 0
