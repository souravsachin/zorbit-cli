#!/usr/bin/env bash
# =============================================================================
# Smoke test for install-sdk-tarball.sh fixes (cycle-105 (w) MSG-079)
# =============================================================================
# Verifies:
#   1. npm-pack tarball with leading `package/` prefix extracts correctly
#      via the new tmpdir-then-swap path. (Bug 1)
#   2. Re-running with same tarball is idempotent (no nested `package/`). (Bug 1)
#   3. A consumer with a baked REAL DIRECTORY SDK copy gets refreshed. (Bug 2)
#   4. A consumer with a SYMLINK SDK is left alone (not re-copied). (Bug 2)
#
# Pre-req: bash, tar, node, mktemp.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${HERE}/../../../install-sdk-tarball.sh"
APP="${HERE}/app"
STAGE="${HERE}/stage"
TARBALLS="${HERE}/tarballs"

PASS=0
FAIL=0

assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: $desc"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL+1))
  fi
}

reset() {
  rm -rf "$APP" "$STAGE" "$TARBALLS"
  mkdir -p "$APP" "$STAGE" "$TARBALLS"
}

build_sdk_tarball() {
  local ver="$1"
  local out="$2"
  local stagedir="${STAGE}/sdk-${ver}/package"
  rm -rf "$stagedir"
  mkdir -p "$stagedir/dist" "$stagedir/scripts" "$stagedir/node_modules/axios" \
           "$stagedir/node_modules/kafkajs" "$stagedir/node_modules/mongoose"
  cat > "$stagedir/package.json" <<JSON
{
  "name": "@zorbit-platform/sdk-node",
  "version": "${ver}",
  "main": "dist/index.js"
}
JSON
  cat > "$stagedir/dist/index.js" <<JS
module.exports = { sdkVersion: '${ver}' };
JS
  cat > "$stagedir/scripts/prune-peer-deps.js" <<'JS'
// no-op for smoke test
JS
  echo '{"name":"axios","version":"1.0.0-test"}' > "$stagedir/node_modules/axios/package.json"
  echo '{"name":"kafkajs","version":"2.0.0-test"}' > "$stagedir/node_modules/kafkajs/package.json"
  echo '{"name":"mongoose","version":"7.0.0-test"}' > "$stagedir/node_modules/mongoose/package.json"
  # Create npm-pack-style tarball: top-level dir is `package/`.
  (cd "${STAGE}/sdk-${ver}" && tar -czf "$out" package)
}

setup_consumer_baked() {
  # Service with a REAL DIRECTORY baked-in SDK copy (the identity / authz / nav
  # pattern). Old version in baked copy.
  local svc="$1"
  local oldver="$2"
  local svcdir="${APP}/${svc}"
  rm -rf "$svcdir"
  mkdir -p "${svcdir}/node_modules/@zorbit-platform/sdk-node/dist" \
           "${svcdir}/node_modules/rxjs"
  cat > "${svcdir}/package.json" <<JSON
{ "name": "${svc}", "version": "0.0.1" }
JSON
  cat > "${svcdir}/node_modules/@zorbit-platform/sdk-node/package.json" <<JSON
{ "name": "@zorbit-platform/sdk-node", "version": "${oldver}" }
JSON
  cat > "${svcdir}/node_modules/@zorbit-platform/sdk-node/dist/index.js" <<JS
module.exports = { sdkVersion: '${oldver}' };
JS
  echo '{"name":"rxjs","version":"7.0.0"}' > "${svcdir}/node_modules/rxjs/package.json"
}

setup_consumer_symlinked() {
  # Service with a SYMLINK to /app/zorbit-sdk-node (the pii-vault pattern).
  local svc="$1"
  local svcdir="${APP}/${svc}"
  rm -rf "$svcdir"
  mkdir -p "${svcdir}/node_modules/@zorbit-platform" "${svcdir}/node_modules/rxjs"
  cat > "${svcdir}/package.json" <<JSON
{ "name": "${svc}", "version": "0.0.1" }
JSON
  ln -sfn "${APP}/zorbit-sdk-node" "${svcdir}/node_modules/@zorbit-platform/sdk-node"
  echo '{"name":"rxjs","version":"7.0.0"}' > "${svcdir}/node_modules/rxjs/package.json"
}

read_baked_ver() {
  local svc="$1"
  node -p "require('${APP}/${svc}/node_modules/@zorbit-platform/sdk-node/package.json').version" 2>/dev/null \
    || echo "MISSING"
}

read_sdk_dir_ver() {
  node -p "require('${APP}/zorbit-sdk-node/package.json').version" 2>/dev/null || echo "MISSING"
}

# -----------------------------------------------------------------------------
echo "=== Test scenario 1: fresh install, npm-pack tarball, baked + symlinked ==="
reset
build_sdk_tarball "0.5.7" "${TARBALLS}/sdk-node-0.5.7.tgz"
setup_consumer_baked     "zorbit-identity"      "0.5.5"
setup_consumer_baked     "zorbit-authorization" "0.5.5"
setup_consumer_symlinked "zorbit-pii-vault"

bash "$INSTALLER" \
  --svc zorbit-identity \
  --sdk-tar "${TARBALLS}/sdk-node-0.5.7.tgz" \
  --app-root "$APP" \
  > "${HERE}/run1.json" 2> "${HERE}/run1.log"

assert "Phase 1 swapped /app/zorbit-sdk-node to 0.5.7" \
  test "$(read_sdk_dir_ver)" = "0.5.7"

assert "no nested package/ subdir under SDK_DIR" \
  test ! -d "${APP}/zorbit-sdk-node/package"

assert "identity baked copy refreshed to 0.5.7" \
  test "$(read_baked_ver zorbit-identity)" = "0.5.7"

assert "authz baked copy refreshed to 0.5.7" \
  test "$(read_baked_ver zorbit-authorization)" = "0.5.7"

assert "pii-vault symlink target unchanged (still a symlink)" \
  test -L "${APP}/zorbit-pii-vault/node_modules/@zorbit-platform/sdk-node"

assert "JSON output declares baked_refreshed includes identity" \
  grep -q '"zorbit-identity"' "${HERE}/run1.json"

assert "JSON output declares baked_refreshed includes authorization" \
  grep -q '"zorbit-authorization"' "${HERE}/run1.json"

assert "JSON output declares pii-vault as skipped (symlinked)" \
  grep -q 'baked_skipped_symlink.*zorbit-pii-vault' "${HERE}/run1.json"

# -----------------------------------------------------------------------------
echo ""
echo "=== Test scenario 2: re-run installer (idempotency check) ==="
bash "$INSTALLER" \
  --svc zorbit-identity \
  --sdk-tar "${TARBALLS}/sdk-node-0.5.7.tgz" \
  --app-root "$APP" \
  > "${HERE}/run2.json" 2> "${HERE}/run2.log"

assert "re-run: SDK_DIR still 0.5.7" \
  test "$(read_sdk_dir_ver)" = "0.5.7"

assert "re-run: still no nested package/ subdir" \
  test ! -d "${APP}/zorbit-sdk-node/package"

assert "re-run: still no nested package/package/ either" \
  test ! -d "${APP}/zorbit-sdk-node/package/package"

assert "re-run: identity baked still 0.5.7" \
  test "$(read_baked_ver zorbit-identity)" = "0.5.7"

# -----------------------------------------------------------------------------
echo ""
echo "=== Test scenario 3: upgrade 0.5.7 → 0.5.8 across baked + symlink ==="
build_sdk_tarball "0.5.8" "${TARBALLS}/sdk-node-0.5.8.tgz"

bash "$INSTALLER" \
  --svc zorbit-identity \
  --sdk-tar "${TARBALLS}/sdk-node-0.5.8.tgz" \
  --app-root "$APP" \
  > "${HERE}/run3.json" 2> "${HERE}/run3.log"

assert "upgrade: SDK_DIR moved to 0.5.8" \
  test "$(read_sdk_dir_ver)" = "0.5.8"

assert "upgrade: identity baked moved to 0.5.8" \
  test "$(read_baked_ver zorbit-identity)" = "0.5.8"

assert "upgrade: authz baked moved to 0.5.8" \
  test "$(read_baked_ver zorbit-authorization)" = "0.5.8"

assert "upgrade: pii-vault still symlinked (resolves to 0.5.8 via SDK_DIR)" \
  test "$(read_baked_ver zorbit-pii-vault)" = "0.5.8"

# -----------------------------------------------------------------------------
echo ""
echo "=== Test scenario 4: tarball WITHOUT package/ prefix (top-level layout) ==="
# Build a tarball where the top-level entries are dist/, package.json, etc.
# Include axios + kafkajs + mongoose to mirror what real SDK tarballs ship,
# so we don't trip the Phase-4 npm-install bake (which is a separate
# concern from the layout detection we want to exercise here).
TOPVER="0.5.9"
TOPSTAGE="${STAGE}/sdk-top-${TOPVER}"
rm -rf "$TOPSTAGE"
mkdir -p "$TOPSTAGE/dist" \
         "$TOPSTAGE/node_modules/axios" \
         "$TOPSTAGE/node_modules/kafkajs" \
         "$TOPSTAGE/node_modules/mongoose"
cat > "$TOPSTAGE/package.json" <<JSON
{ "name": "@zorbit-platform/sdk-node", "version": "${TOPVER}", "main": "dist/index.js" }
JSON
echo "module.exports={sdkVersion:'${TOPVER}'}" > "$TOPSTAGE/dist/index.js"
echo '{"name":"axios","version":"1.0.0-test"}' > "$TOPSTAGE/node_modules/axios/package.json"
echo '{"name":"kafkajs","version":"2.0.0-test"}' > "$TOPSTAGE/node_modules/kafkajs/package.json"
echo '{"name":"mongoose","version":"7.0.0-test"}' > "$TOPSTAGE/node_modules/mongoose/package.json"
(cd "$TOPSTAGE" && tar -czf "${TARBALLS}/sdk-node-top-${TOPVER}.tgz" .)

bash "$INSTALLER" \
  --svc zorbit-identity \
  --sdk-tar "${TARBALLS}/sdk-node-top-${TOPVER}.tgz" \
  --app-root "$APP" \
  > "${HERE}/run4.json" 2> "${HERE}/run4.log"

assert "top-level tarball: SDK_DIR is ${TOPVER}" \
  test "$(read_sdk_dir_ver)" = "${TOPVER}"

assert "top-level tarball: still no nested package/" \
  test ! -d "${APP}/zorbit-sdk-node/package"

assert "top-level tarball: identity baked refreshed to ${TOPVER}" \
  test "$(read_baked_ver zorbit-identity)" = "${TOPVER}"

# -----------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  RESULT: ${PASS} passed, ${FAIL} failed"
echo "================================================================"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
