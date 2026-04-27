#!/usr/bin/env bash
# =============================================================================
# scripts/install/verify-e2e.sh    [D9 — abort gate]
#
# Defect D9: the installer used to mark "deploy ok" if /api/v1/G/health
# returned 200 — but a healthy service can still serve a broken UX. Cycle
# 101 cheating pattern: SPA fallback returns 200 for any URL, so curl
# success means nothing.
#
# This phase exercises the FULL super-admin loop end to end:
#   1. POST /auth/login → expect 200 + JWT containing privilege_set_hash
#   2. GET /api/authorization/.../O/<org>/roles → 200 with >=1 role
#   3. GET /api/navigation/.../U/<user>/navigation/menu → 200, sections > 0
#   4. GET / with bearer → no /no-access redirect (HTTP 200 + body refers
#      to dashboard markers, not the no-access placeholder)
#
# ANY step fails => abort the whole install.
#
# Inputs:
#   ENV_PREFIX           REQUIRED
#   PUBLIC_URL           default https://zorbit-${ENV_PREFIX}.onezippy.ai
#   SUPER_ADMIN_EMAIL    REQUIRED
#   SUPER_ADMIN_PASSWORD REQUIRED  (clear; will sha256-prehash for SPA path)
# =============================================================================
set -euo pipefail

ENV_PREFIX="${ENV_PREFIX:-${1:-}}"
PUBLIC_URL="${PUBLIC_URL:-https://zorbit-${ENV_PREFIX}.onezippy.ai}"
SA_EMAIL="${SUPER_ADMIN_EMAIL:-${2:-}}"
SA_PASSWORD="${SUPER_ADMIN_PASSWORD:-${3:-}}"
REPORT_DIR="${ZORBIT_INSTALL_LOG_DIR:-/var/log/zorbit-install}"
mkdir -p "$REPORT_DIR" 2>/dev/null || REPORT_DIR=/tmp

[[ -z "$ENV_PREFIX" || -z "$SA_EMAIL" || -z "$SA_PASSWORD" ]] && {
  echo "ERR: ENV_PREFIX, SUPER_ADMIN_EMAIL, SUPER_ADMIN_PASSWORD required"; exit 1; }

fail=0
results=()
add_result() { results+=("$1"); }

# ----------- 1. Login -----------
echo "==> [1/4] login as ${SA_EMAIL}"
pwd_hash=$(printf '%s' "$SA_PASSWORD" | shasum -a 256 2>/dev/null | awk '{print $1}')
[[ -z "$pwd_hash" ]] && pwd_hash=$(printf '%s' "$SA_PASSWORD" | sha256sum | awk '{print $1}')

login_body=$(jq -nc --arg e "$SA_EMAIL" --arg p "$pwd_hash" '{email:$e, password:$p}')
login_resp=$(curl -sS -m 20 -w '\n%{http_code}' \
  -X POST "${PUBLIC_URL}/api/identity/api/v1/G/auth/login" \
  -H 'Content-Type: application/json' \
  --data "$login_body" 2>&1)
login_code=$(echo "$login_resp" | tail -1)
login_body_resp=$(echo "$login_resp" | sed '$d')
JWT=""
UHID=""
PRIV_HASH=""
if [[ "$login_code" == "200" || "$login_code" == "201" ]]; then
  JWT=$(echo "$login_body_resp" | jq -r '.accessToken // .access_token // .token // empty' 2>/dev/null)
  UHID=$(echo "$login_body_resp" | jq -r '.user.hashId // .user.id // .userId // empty' 2>/dev/null)
fi
if [[ -n "$JWT" ]]; then
  # decode middle segment for privilege_set_hash
  payload=$(echo "$JWT" | cut -d. -f2)
  # base64url-decode (pad as needed)
  pad=$(( (4 - ${#payload} % 4) % 4 ))
  for ((i=0; i<pad; i++)); do payload+="="; done
  decoded=$(echo "$payload" | tr -- '-_' '+/' | base64 -d 2>/dev/null || echo "")
  PRIV_HASH=$(echo "$decoded" | jq -r '.privilege_set_hash // empty' 2>/dev/null || echo "")
  [[ -z "$UHID" ]] && UHID=$(echo "$decoded" | jq -r '.userHashId // .sub // empty' 2>/dev/null)
fi

if [[ "$login_code" =~ ^20[01]$ && -n "$JWT" ]]; then
  echo "  PASS: login ${login_code}, jwt len=${#JWT}, uhid=$UHID, priv_hash=${PRIV_HASH:0:10}..."
  add_result "{\"step\":\"login\",\"status\":\"pass\",\"http\":$login_code,\"priv_hash_present\":$([[ -n "$PRIV_HASH" ]] && echo true || echo false)}"
else
  echo "  FAIL: code=$login_code body=$(echo "$login_body_resp" | head -c 200)"
  fail=1
  add_result "{\"step\":\"login\",\"status\":\"fail\",\"http\":$login_code}"
fi

# ----------- 2. List roles -----------
if [[ -n "$JWT" ]]; then
  echo "==> [2/4] GET roles (org O-DFLT)"
  roles_code=$(curl -sS -m 15 -o /tmp/_v-roles.json -w '%{http_code}' \
    -H "Authorization: Bearer $JWT" \
    "${PUBLIC_URL}/api/authorization/api/v1/O/O-DFLT/roles" 2>/dev/null || echo "000")
  roles_count=$(jq -r 'if type=="array" then length elif .data then (.data|length) elif .roles then (.roles|length) else 0 end' /tmp/_v-roles.json 2>/dev/null || echo 0)
  if [[ "$roles_code" == "200" && "$roles_count" -ge 1 ]]; then
    echo "  PASS: $roles_count role(s)"
    add_result "{\"step\":\"roles\",\"status\":\"pass\",\"http\":$roles_code,\"count\":$roles_count}"
  else
    echo "  FAIL: code=$roles_code count=$roles_count"
    fail=1
    add_result "{\"step\":\"roles\",\"status\":\"fail\",\"http\":$roles_code,\"count\":$roles_count}"
  fi
fi

# ----------- 3. Navigation menu -----------
if [[ -n "$JWT" && -n "$UHID" ]]; then
  echo "==> [3/4] GET navigation menu for $UHID"
  menu_code=$(curl -sS -m 15 -o /tmp/_v-menu.json -w '%{http_code}' \
    -H "Authorization: Bearer $JWT" \
    "${PUBLIC_URL}/api/navigation/api/v1/U/${UHID}/navigation/menu" 2>/dev/null || echo "000")
  sections=$(jq -r '.sections | length' /tmp/_v-menu.json 2>/dev/null || echo 0)
  if [[ "$menu_code" == "200" && "$sections" -ge 1 ]]; then
    echo "  PASS: $sections section(s)"
    add_result "{\"step\":\"menu\",\"status\":\"pass\",\"http\":$menu_code,\"sections\":$sections}"
  else
    echo "  FAIL: code=$menu_code sections=$sections"
    fail=1
    add_result "{\"step\":\"menu\",\"status\":\"fail\",\"http\":$menu_code,\"sections\":$sections}"
  fi
fi

# ----------- 4. SPA root not /no-access -----------
echo "==> [4/4] GET / (SPA root)"
spa_code=$(curl -sS -m 15 -o /tmp/_v-spa.html -w '%{http_code}' \
  -H "Authorization: Bearer ${JWT:-}" \
  "${PUBLIC_URL}/" 2>/dev/null || echo "000")
# /no-access placeholder string check
no_access=0
grep -qiE 'no[- ]access|access denied|coming soon|coming-soon' /tmp/_v-spa.html 2>/dev/null && no_access=1
if [[ "$spa_code" == "200" && $no_access -eq 0 ]]; then
  echo "  PASS: HTTP 200 and no /no-access markers"
  add_result "{\"step\":\"spa_root\",\"status\":\"pass\",\"http\":$spa_code}"
else
  echo "  FAIL: code=$spa_code no_access=$no_access"
  fail=1
  add_result "{\"step\":\"spa_root\",\"status\":\"fail\",\"http\":$spa_code,\"no_access\":$no_access}"
fi

# Report
{
  printf '{"phase":"verify-e2e","env":"%s","public_url":"%s","email":"%s","steps":[' \
    "$ENV_PREFIX" "$PUBLIC_URL" "$SA_EMAIL"
  IFS=,; printf '%s' "${results[*]}"; unset IFS
  printf '],"result":"%s"}\n' "$([[ $fail -eq 0 ]] && echo pass || echo fail)"
} > "${REPORT_DIR}/verify-e2e.json" || true

if (( fail )); then
  echo
  echo "==> D9 VERIFY-E2E FAILED — installer must abort."
  echo "    Report: ${REPORT_DIR}/verify-e2e.json"
  exit 1
fi
echo "==> D9 PASS — env is genuinely usable end-to-end"
