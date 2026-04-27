#!/usr/bin/env bash
# =============================================================================
# scripts/install/prime-navigation-cache.sh    [D8]
#
# Defect D8: even after privileges + roles + module_registry were seeded,
# the navigation menu API returned `sections: []`. The cascade resolver
# needs:
#   - module_registry data
#   - slug-translations.json
#   - live-services check
# Any of those missing => empty sections.
#
# This phase forces the cache to rebuild AND verifies sections > 0 for a
# super-admin token.
#
# Inputs:
#   ENV_PREFIX           REQUIRED
#   PUBLIC_URL           default https://zorbit-${ENV_PREFIX}.onezippy.ai
#   ADMIN_JWT            REQUIRED
#   ADMIN_USER_HASH_ID   REQUIRED
#   ENV_CORE_CONTAINER   default ${ENV_PREFIX}-core
#   SSH_TARGET           default ''
# =============================================================================
set -euo pipefail

ENV_PREFIX="${ENV_PREFIX:-${1:-}}"
case "$ENV_PREFIX" in
  ze) ENV_HOSTNAME_SLUG=dev ;; zq) ENV_HOSTNAME_SLUG=qa ;; zd) ENV_HOSTNAME_SLUG=demo ;;
  zu) ENV_HOSTNAME_SLUG=uat ;; zp) ENV_HOSTNAME_SLUG=prod ;; *) ENV_HOSTNAME_SLUG="$ENV_PREFIX" ;;
esac
PUBLIC_URL="${PUBLIC_URL:-https://zorbit-${ENV_HOSTNAME_SLUG}.onezippy.ai}"
ADMIN_JWT="${ADMIN_JWT:-}"
ADMIN_UHID="${ADMIN_USER_HASH_ID:-${2:-}}"
CORE_CONTAINER="${ENV_CORE_CONTAINER:-${ENV_PREFIX}-core}"
SSH_TARGET="${SSH_TARGET:-}"
REPORT_DIR="${ZORBIT_INSTALL_LOG_DIR:-/var/log/zorbit-install}"
mkdir -p "$REPORT_DIR" 2>/dev/null || REPORT_DIR=/tmp

[[ -z "$ENV_PREFIX" || -z "$ADMIN_JWT" || -z "$ADMIN_UHID" ]] && {
  echo "ERR: ENV_PREFIX, ADMIN_JWT, ADMIN_USER_HASH_ID all required"; exit 1; }

# Step 1: restart navigation service so cascade resolver re-reads source
echo "==> bouncing navigation service to drop in-memory cache"
if [[ -n "$SSH_TARGET" ]]; then
  ssh "$SSH_TARGET" "sudo docker exec $CORE_CONTAINER pm2 restart zorbit-navigation" >/dev/null 2>&1 || true
else
  docker exec "$CORE_CONTAINER" pm2 restart zorbit-navigation >/dev/null 2>&1 || true
fi
# Wait for navigation to come back up — poll /health for ≤ 60s
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 5
  health_code=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/api/navigation/api/v1/G/health" 2>/dev/null || echo "000")
  [[ "$health_code" == "200" ]] && { echo "  navigation healthy after $((i*5))s"; break; }
done

# Step 2: hit the rebuild endpoint (best-effort; not all builds expose it)
echo "==> POST cache/rebuild (non-fatal if endpoint missing)"
curl -sS -m 15 -o /tmp/_nav-rebuild.json -w 'rebuild_code=%{http_code}\n' \
  -X POST "${PUBLIC_URL}/api/navigation/api/v1/G/cache/rebuild" \
  -H "Authorization: Bearer ${ADMIN_JWT}" 2>&1 | tail -1 || true

# Step 3: verify sections > 0 for super-admin
echo "==> verifying menu has > 0 sections"
http_code=$(curl -sS -m 15 -o /tmp/_nav-menu.json -w '%{http_code}' \
  -H "Authorization: Bearer ${ADMIN_JWT}" \
  "${PUBLIC_URL}/api/navigation/api/v1/U/${ADMIN_UHID}/navigation/menu" 2>/dev/null || echo "000")

sections=0
if [[ -f /tmp/_nav-menu.json ]]; then
  sections=$(jq -r '.sections | length' /tmp/_nav-menu.json 2>/dev/null || echo 0)
fi

echo "  HTTP $http_code, sections.length=$sections"

{
  printf '{"phase":"prime-navigation-cache","env":"%s","menu_http":"%s","sections":%s,"result":"%s"}\n' \
    "$ENV_PREFIX" "$http_code" "$sections" \
    "$([[ "$sections" =~ ^[0-9]+$ && "$sections" -gt 0 ]] && echo pass || echo fail)"
} > "${REPORT_DIR}/prime-navigation-cache.json" || true

if [[ "$sections" -le 0 ]]; then
  echo "==> D8 FAILED — menu still has 0 sections"
  echo "    Response head: $(head -c 400 /tmp/_nav-menu.json 2>/dev/null)"
  exit 1
fi
echo "==> D8 PASS"
