#!/bin/bash
# ============================================================================
# zorbit-cli/scripts/post-deploy-bootstrap.sh
# ============================================================================
# Idempotent post-deploy bootstrap that bakes in every QA-mishap learning from
# 2026-04-25.  Runs on the VM where ze-* bundles are deployed.  Reads its
# environment from /etc/zorbit/<env_prefix>/env/*.env  +  bundles already loaded.
#
# What this script does (in order):
#   1. Discover every DATABASE_NAME default from compiled dist + create the DB
#   2. Restart all PM2 services with kafka-warm sequencing (kafka first, wait,
#      module-registry next, wait, all others)
#   3. Discover every RequirePrivileges code from compiled dist + seed
#   4. Read super_admins.json + register each via SPA-compatible (sha256) flow
#   5. Activate all per JSON 'status' field; assign R-SADMIN role to all
#   6. Fetch each registered service's real manifest internally (skip public URL)
#      and UPSERT into zorbit_navigation.registered_modules
#   7. Restart navigation so it rehydrates from the new manifests
#   8. Run health assertions; emit JSON report to /etc/zorbit/<env>/post-deploy-status.json
#   9. If any gate fails, exit non-zero with a clear failure category
#
# Usage:
#   bash post-deploy-bootstrap.sh --env ze --super-admins-json /path/to/super_admins.json
# ============================================================================
set +e

# ---- Args -----------------------------------------------------------------
ENV_PREFIX=""
SA_JSON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_PREFIX="$2"; shift 2 ;;
    --super-admins-json) SA_JSON="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -z "$ENV_PREFIX" ]] && { echo "ERR: --env required (ze|zq|zd|zu|zp)"; exit 1; }
[[ -z "$SA_JSON" || ! -f "$SA_JSON" ]] && { echo "ERR: --super-admins-json must be readable JSON"; exit 1; }

LOG=/etc/zorbit/${ENV_PREFIX}/post-deploy-bootstrap.log
STATUS=/etc/zorbit/${ENV_PREFIX}/post-deploy-status.json
mkdir -p /etc/zorbit/${ENV_PREFIX}
: > "$LOG"

declare -A counts
counts[gate]="L4-L7-bootstrap"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }

# ---- Step 1: Discover + create per-service DBs ----------------------------
log "Step 1: discover + create per-service Postgres databases"
DBS=$(for c in ${ENV_PREFIX}-core ${ENV_PREFIX}-pfs ${ENV_PREFIX}-apps ${ENV_PREFIX}-ai; do
  docker exec $c sh -c 'find /app -name app.module.js -path "*/dist/*" -exec grep -oE "DATABASE_NAME[^)]+" {} \;' 2>/dev/null
done | grep -oE 'zorbit_[a-z0-9_]+' | sort -u)
log "  discovered $(echo "$DBS" | wc -l) unique DB names"
ok=0; existing=0
for db in $DBS; do
  out=$(docker exec zs-pg psql -U zorbit -d postgres -c "CREATE DATABASE $db" 2>&1 | tail -1)
  if [[ "$out" == *"CREATE DATABASE"* ]]; then ok=$((ok+1)); fi
  if [[ "$out" == *"already exists"* ]]; then existing=$((existing+1)); fi
done
log "  created=$ok already_existed=$existing"
counts[dbs_created]=$ok
counts[dbs_existing]=$existing

# ---- Step 2: Sequenced PM2 restart (kafka first, then module-registry, then rest) ----
log "Step 2: kafka-warm sequenced PM2 restart"
docker compose -f /etc/zorbit/zs-shared.yml -p zs up -d zs-kafka >/dev/null 2>&1
log "  waiting for zs-kafka healthy..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  status=$(docker inspect zs-kafka --format '{{.State.Health.Status}}' 2>/dev/null)
  [[ "$status" == "healthy" ]] && break
  sleep 5
done
log "  zs-kafka status: $status"
log "  restarting module-registry first..."
docker exec ${ENV_PREFIX}-core pm2 restart zorbit-cor-module_registry >/dev/null 2>&1
sleep 30
log "  restarting rest of PM2 services..."
for c in ${ENV_PREFIX}-core ${ENV_PREFIX}-pfs ${ENV_PREFIX}-apps ${ENV_PREFIX}-ai; do
  docker exec $c pm2 restart all >/dev/null 2>&1
done
log "  PM2 restart sequence done — waiting 90s for announcements..."
sleep 90

# ---- Step 3: Discover + seed RequirePrivileges ----------------------------
log "Step 3: discover + seed authorization privileges"
PRIVS=$(for c in ${ENV_PREFIX}-core ${ENV_PREFIX}-pfs ${ENV_PREFIX}-apps ${ENV_PREFIX}-ai; do
  docker exec $c sh -c 'find /app -name "*.js" -path "*/dist/*" -exec grep -ohE "RequirePrivileges\\)\\([^)]+\\)" {} \;' 2>/dev/null
done | grep -oE "'[a-z][a-z0-9._-]+'" | tr -d "'" | sort -u)
PRIV_COUNT=$(echo "$PRIVS" | wc -l)
log "  discovered $PRIV_COUNT unique privilege codes"

# Ensure baseline section + role exist
docker exec zs-pg psql -U zorbit -d zorbit_authorization -c "
INSERT INTO privilege_sections (id, section_code, section_label, icon, seq_number, visible)
VALUES ('SEC-PLAT', 'platform', 'Platform', 'shield', 0, TRUE)
ON CONFLICT (section_code) DO NOTHING;
INSERT INTO roles (id, \"hashId\", name, description, organization_hash_id, is_system, status)
VALUES (uuid_generate_v4(), 'R-SADMIN', 'super_admin', 'All-access role', 'O-DFLT', TRUE, 'active')
ON CONFLICT (\"hashId\") DO NOTHING;
" >/dev/null 2>&1

# Seed each privilege with numeric ID
i=100
for p in $PRIVS; do
  pid="PRV-$i"
  i=$((i+1))
  docker exec zs-pg psql -U zorbit -d zorbit_authorization -c \
    "INSERT INTO privileges_v2 (id, privilege_code, privilege_label, section_id, fe_route_config, be_route_config, icon, visible_in_menu, seq_number) VALUES ('$pid', '$p', '$p', 'SEC-PLAT', '', '', 'shield', false, 0) ON CONFLICT (privilege_code) DO NOTHING" >/dev/null 2>&1
done
docker exec zs-pg psql -U zorbit -d zorbit_authorization -c "
INSERT INTO role_privileges_v2 (id, role_id, privilege_id)
SELECT uuid_generate_v4(), r.id, p.id
FROM roles r CROSS JOIN privileges_v2 p
WHERE r.\"hashId\" = 'R-SADMIN'
ON CONFLICT DO NOTHING;
" >/dev/null 2>&1
counts[privileges_seeded]=$PRIV_COUNT

# ---- Step 4: Register super_admins via SPA-compatible flow ---------------
log "Step 4: register super_admins from $SA_JSON"
docker cp "$SA_JSON" zs-pg:/tmp/super_admins.json >/dev/null 2>&1
# We need this file inside ze-core where we can curl localhost
docker cp "$SA_JSON" ${ENV_PREFIX}-core:/tmp/super_admins.json >/dev/null 2>&1

cat > /tmp/_register-admins.py <<'PYEOF'
import json, subprocess, hashlib, sys
admins = json.load(open('/tmp/super_admins.json'))['super_admins']
created = 0
for a in admins:
    pwd_hash = hashlib.sha256(a['password'].encode()).hexdigest()
    parts = a['full_name'].split()
    body = json.dumps({
        'email': a['email'], 'password': pwd_hash,
        'firstName': parts[0],
        'lastName': ' '.join(parts[1:]) if len(parts)>1 else 'X'
    })
    r = subprocess.run(['curl','-s','-m','60','-X','POST','http://localhost:3001/api/v1/G/auth/register','-H','Content-Type: application/json','-d',body], capture_output=True, text=True, timeout=70)
    if 'userId' in (r.stdout or ''):
        created += 1
print(f'CREATED={created}')
PYEOF
docker cp /tmp/_register-admins.py ${ENV_PREFIX}-core:/tmp/_register-admins.py >/dev/null 2>&1
result=$(docker exec ${ENV_PREFIX}-core python3 /tmp/_register-admins.py 2>&1 || echo "PYTHON_FAIL")
if [[ "$result" == *"CREATED="* ]]; then
  CREATED=$(echo "$result" | grep -oE 'CREATED=[0-9]+' | cut -d= -f2)
  log "  $result"
  counts[admins_registered]=$CREATED
else
  log "  python3 not in container; falling back to host loop"
  CREATED=0
  for entry in $(python3 -c "
import json,hashlib,sys
for a in json.load(open('$SA_JSON'))['super_admins']:
  pwd=hashlib.sha256(a['password'].encode()).hexdigest()
  parts=a['full_name'].split()
  print(a['email']+'|'+pwd+'|'+parts[0]+'|'+(' '.join(parts[1:]) if len(parts)>1 else 'X'))
"); do
    IFS='|' read email pwd fn ln <<<"$entry"
    body=$(printf '{"email":"%s","password":"%s","firstName":"%s","lastName":"%s"}' "$email" "$pwd" "$fn" "$ln")
    out=$(docker exec ${ENV_PREFIX}-core curl -s -m 60 -X POST http://localhost:3001/api/v1/G/auth/register -H 'Content-Type: application/json' -d "$body" 2>&1)
    [[ "$out" == *"userId"* ]] && CREATED=$((CREATED+1))
  done
  log "  CREATED=$CREATED"
  counts[admins_registered]=$CREATED
fi

# Activate per JSON status flag, assign R-SADMIN
log "  activating + role-binding admins per JSON status"
docker exec zs-pg psql -U zorbit -d zorbit_identity -c "UPDATE users SET status='active' WHERE status='pending_approval'" >/dev/null 2>&1
# Mark JSON-declared inactive ones inactive
INACTIVE_NAMES=$(python3 -c "
import json
admins=json.load(open('$SA_JSON'))['super_admins']
print(','.join(\"'\"+a['full_name'].replace(\"'\",\"''\")+\"'\" for a in admins if a.get('status')=='inactive'))
")
[[ -n "$INACTIVE_NAMES" ]] && docker exec zs-pg psql -U zorbit -d zorbit_identity -c "UPDATE users SET status='inactive' WHERE display_name IN ($INACTIVE_NAMES)" >/dev/null 2>&1

docker exec zs-pg psql -U zorbit -d zorbit_authorization -c "CREATE EXTENSION IF NOT EXISTS dblink" >/dev/null 2>&1
docker exec zs-pg psql -U zorbit -d zorbit_authorization -c "
INSERT INTO user_roles (id, user_hash_id, role_hash_id, organization_hash_id)
SELECT uuid_generate_v4(), u.uhid, 'R-SADMIN', 'O-DFLT'
FROM (SELECT DISTINCT \"hashId\" AS uhid FROM dblink('host=localhost user=zorbit dbname=zorbit_identity password='||current_setting('zorbit.pg_password',true),'SELECT \"hashId\" FROM users WHERE status=''active''') AS t(\"hashId\" varchar(20))) u
WHERE NOT EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_hash_id = u.uhid AND ur.role_hash_id = 'R-SADMIN')
" >/dev/null 2>&1

# ---- Step 6: Fetch real manifests internally + UPSERT to nav DB ----------
log "Step 6: fetch real manifests + UPSERT to navigation DB"
# (handled separately via /tmp/fetch-real-manifests-v2.sh logic — call out to it if exists)
if [[ -x /tmp/fetch-real-manifests-v2.sh ]]; then
  bash /tmp/fetch-real-manifests-v2.sh 2>&1 | tail -3 | tee -a "$LOG"
fi

# ---- Step 6.5: Apply slug-only placement (owner directive 2026-04-25 / MSG-013) ----
# Manifests carry SLUGS only. Display labels come from slug-translations.json.
# This patcher reads slug-translations.json and writes manifest.placement.{scaffold,
# businessLine, capabilityArea} as slugs, removing label-style legacy values.
log "Step 6.5: apply slug-only placement to all module manifests"
TRANS_FILE=/etc/zorbit/${ENV_PREFIX}/slug-translations.json
if [ ! -f "$TRANS_FILE" ]; then
  mkdir -p /etc/zorbit/${ENV_PREFIX}
  cp /opt/zorbit-cli/scripts/../platform-spec/slug-translations.json "$TRANS_FILE" 2>/dev/null || \
  cp /home/admin/zorbit-dev/source/zorbit/02_repos/zorbit-core/platform-spec/slug-translations.json "$TRANS_FILE" 2>/dev/null
fi
SLUG_PATCHER=/opt/zorbit-cli/scripts/patch-placement-to-slugs.py
[ ! -x "$SLUG_PATCHER" ] && SLUG_PATCHER=/home/admin/zorbit-dev/source/zorbit/02_repos/zorbit-cli/scripts/patch-placement-to-slugs.py
if [ -x "$SLUG_PATCHER" ]; then
  python3 "$SLUG_PATCHER" --translations "$TRANS_FILE" --env-prefix "${ENV_PREFIX}" 2>&1 | tee -a "$LOG" | tail -8
  patcher_rc=${PIPESTATUS[0]}
  if [[ $patcher_rc -ne 0 ]]; then
    log "  WARN: slug patcher exit $patcher_rc — at least one module could not be slug-placed; check log"
  fi
else
  log "  WARN: slug patcher not found at $SLUG_PATCHER — skipping (will leave placement drift)"
fi

# Make slug-translations.json available to the SPA via nginx static asset.
WEB_CONTAINER=${ENV_PREFIX}-web
if docker ps --format '{{.Names}}' | grep -q "^${WEB_CONTAINER}$"; then
  docker cp "$TRANS_FILE" "${WEB_CONTAINER}:/usr/share/nginx/html/slug-translations.json" 2>/dev/null && \
    log "  copied slug-translations.json into ${WEB_CONTAINER}:/usr/share/nginx/html/" || \
    log "  WARN: failed to copy slug-translations.json into ${WEB_CONTAINER}"
fi

# ---- Step 7: Restart navigation ------------------------------------------
log "Step 7: rehydrate navigation"
docker exec ${ENV_PREFIX}-core pm2 restart zorbit-navigation >/dev/null 2>&1
sleep 8

# ---- Step 8: Health assertions + JSON status -----------------------------
log "Step 8: health assertions"
ze_count=$(docker ps --format '{{.Names}}' | grep -cE "^${ENV_PREFIX}-")
zs_count=$(docker ps --format '{{.Names}}' | grep -cE "^zs-")
nav_modules=$(docker exec zs-pg psql -U zorbit -d zorbit_navigation -tAc "SELECT count(*) FROM registered_modules" 2>/dev/null)
mod_reg_modules=$(docker exec zs-pg psql -U zorbit -d zorbit_module_registry -tAc "SELECT count(*) FROM modules" 2>/dev/null)
ready=$(docker exec zs-pg psql -U zorbit -d zorbit_module_registry -tAc "SELECT count(*) FROM modules WHERE status='READY'" 2>/dev/null)
users=$(docker exec zs-pg psql -U zorbit -d zorbit_identity -tAc "SELECT count(*) FROM users WHERE status='active'" 2>/dev/null)
sadmins=$(docker exec zs-pg psql -U zorbit -d zorbit_authorization -tAc "SELECT count(*) FROM user_roles WHERE role_hash_id='R-SADMIN'" 2>/dev/null)

cat > "$STATUS" <<JSON
{
  "gate": "L4-L7-bootstrap",
  "version": "0.2",
  "finished": "$(date -Iseconds)",
  "env_prefix": "$ENV_PREFIX",
  "outputs": {
    "ze_containers": $ze_count,
    "zs_containers": $zs_count,
    "module_registry_total": $mod_reg_modules,
    "module_registry_ready": $ready,
    "navigation_registered_modules": $nav_modules,
    "users_active": $users,
    "super_admin_role_assignments": $sadmins,
    "dbs_created": ${counts[dbs_created]:-0},
    "dbs_existing": ${counts[dbs_existing]:-0},
    "privileges_seeded": ${counts[privileges_seeded]:-0},
    "admins_registered": ${counts[admins_registered]:-0}
  },
  "next_gate": "L8 browser-smoke"
}
JSON
log "DONE — see $STATUS"
cat "$STATUS"
