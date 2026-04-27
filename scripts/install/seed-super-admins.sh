#!/usr/bin/env bash
# =============================================================================
# scripts/install/seed-super-admins.sh    [D5 + D6]
#
# Defects D5 + D6:
#   D5: post-deploy seeded admin_assignments but NOT user_roles. SPA
#       depends on user_roles for privilege resolution.
#   D6: users.role left NULL — identity issued JWT with role:'member' so
#       SPA's role-fallback gate refused everything.
#
# This phase, for every super_admin in <env>/super_admins.json:
#   (a) registers the user via SPA-compatible POST /auth/register (sha256
#       pre-hash of password)
#   (b) UPDATES zorbit_identity.users SET role='super_admin'
#   (c) INSERTS zorbit_identity.admin_assignments (scope_level='super_admin')
#   (d) INSERTS zorbit_authorization.user_roles linking user to R-SADMIN
#
# Idempotent.
#
# Inputs:
#   ENV_PREFIX            REQUIRED
#   SUPER_ADMINS_JSON     REQUIRED  path to JSON file with super_admins[]
#   PG_CONTAINER          default zs-pg
#   ENV_CORE_CONTAINER    default ${ENV_PREFIX}-core
#   IDENTITY_PORT         default 3001
#   SSH_TARGET            default ''
# =============================================================================
set -euo pipefail

ENV_PREFIX="${ENV_PREFIX:-${1:-}}"
SA_JSON="${SUPER_ADMINS_JSON:-${2:-}}"
PG_CONTAINER="${PG_CONTAINER:-zs-pg}"
CORE_CONTAINER="${ENV_CORE_CONTAINER:-${ENV_PREFIX}-core}"
IDENTITY_PORT="${IDENTITY_PORT:-3001}"
SSH_TARGET="${SSH_TARGET:-}"
REPORT_DIR="${ZORBIT_INSTALL_LOG_DIR:-/var/log/zorbit-install}"
mkdir -p "$REPORT_DIR" 2>/dev/null || REPORT_DIR=/tmp

[[ -z "$ENV_PREFIX" ]] && { echo "ERR: ENV_PREFIX required"; exit 1; }
[[ -z "$SA_JSON" || ! -f "$SA_JSON" ]] && { echo "ERR: SUPER_ADMINS_JSON file required"; exit 1; }

run_pg() {
  local db="$1" sql="$2"
  if [[ -n "$SSH_TARGET" ]]; then
    ssh "$SSH_TARGET" "sudo docker exec -i $PG_CONTAINER psql -U zorbit -d $db" <<<"$sql"
  else
    docker exec -i "$PG_CONTAINER" psql -U zorbit -d "$db" <<<"$sql"
  fi
}

run_core() {
  local cmd="$1"
  if [[ -n "$SSH_TARGET" ]]; then
    ssh "$SSH_TARGET" "sudo docker exec $CORE_CONTAINER sh -c \"$cmd\""
  else
    docker exec "$CORE_CONTAINER" sh -c "$cmd"
  fi
}

# Step (a): register every admin via /auth/register
echo "==> Step (a) registering super_admins via /auth/register"
if [[ -n "$SSH_TARGET" ]]; then
  scp -q "$SA_JSON" "$SSH_TARGET:/tmp/super_admins.json"
  ssh "$SSH_TARGET" "sudo docker cp /tmp/super_admins.json $CORE_CONTAINER:/tmp/super_admins.json"
else
  docker cp "$SA_JSON" "$CORE_CONTAINER:/tmp/super_admins.json"
fi

cat > /tmp/_register-admins.py <<PYEOF
import json, subprocess, hashlib
admins = json.load(open('/tmp/super_admins.json'))['super_admins']
created = 0
existed = 0
for a in admins:
    pwd_hash = hashlib.sha256(a['password'].encode()).hexdigest()
    name = a.get('full_name') or a.get('name') or a['email'].split('@')[0]
    parts = name.split()
    body = json.dumps({
        'email': a['email'], 'password': pwd_hash,
        'firstName': parts[0],
        'lastName': ' '.join(parts[1:]) if len(parts)>1 else 'X'
    })
    r = subprocess.run(['curl','-s','-m','60','-X','POST',
                        f'http://localhost:${IDENTITY_PORT}/api/v1/G/auth/register',
                        '-H','Content-Type: application/json','-d',body],
                       capture_output=True, text=True, timeout=70)
    out = r.stdout or ''
    if 'userId' in out: created += 1
    elif 'already' in out.lower() or 'exists' in out.lower(): existed += 1
print(f'CREATED={created} EXISTED={existed}')
PYEOF

if [[ -n "$SSH_TARGET" ]]; then
  scp -q /tmp/_register-admins.py "$SSH_TARGET:/tmp/_register-admins.py"
  ssh "$SSH_TARGET" "sudo docker cp /tmp/_register-admins.py $CORE_CONTAINER:/tmp/_register-admins.py"
else
  docker cp /tmp/_register-admins.py "$CORE_CONTAINER:/tmp/_register-admins.py"
fi
register_out=$(run_core "python3 /tmp/_register-admins.py" 2>&1 | tail -1 || echo "FAIL")
echo "  $register_out"

# Step (b): set users.role='super_admin' for every email in super_admins.json
echo "==> Step (b) marking users.role=super_admin"
emails=$(jq -r '.super_admins[].email' "$SA_JSON" | sed "s/'/''/g" | awk '{print "\x27"$0"\x27"}' | paste -sd, -)
run_pg zorbit_identity "UPDATE users SET role='super_admin', status='active' WHERE email IN ($emails);" >/dev/null
roles_set=$(run_pg zorbit_identity "SELECT COUNT(*) FROM users WHERE role='super_admin' AND email IN ($emails);" 2>&1 | tail -1 | tr -d ' ')
echo "  users marked: $roles_set"

# Step (c): admin_assignments
echo "==> Step (c) writing admin_assignments"
run_pg zorbit_identity "
INSERT INTO admin_assignments (id, user_hash_id, scope_level, scope_id, granted_by, granted_at)
SELECT uuid_generate_v4(), \"hashId\", 'super_admin', NULL, 'system', NOW()
FROM users WHERE email IN ($emails)
ON CONFLICT DO NOTHING;
" >/dev/null 2>&1 || echo "  (admin_assignments table may not exist or have different schema — non-fatal)"

# Step (d): user_roles (links to R-SADMIN). The user_hash_id comes from
# zorbit_identity.users."hashId"; we have to query it then INSERT into
# zorbit_authorization.user_roles. Two-step query (no dblink dep).
echo "==> Step (d) granting R-SADMIN via user_roles"
hash_ids=$(run_pg zorbit_identity "SELECT \"hashId\" FROM users WHERE email IN ($emails);" | grep -oE 'U-[A-Z0-9]+' | sort -u)
grants=0
for h in $hash_ids; do
  out=$(run_pg zorbit_authorization "
    INSERT INTO user_roles (id, user_hash_id, role_hash_id, organization_hash_id)
    VALUES (uuid_generate_v4(), '$h', 'R-SADMIN', 'O-DFLT')
    ON CONFLICT DO NOTHING RETURNING id;
  " 2>&1)
  echo "$out" | grep -q '[0-9a-f-]\{36\}' && grants=$((grants+1)) || true
done
echo "  user_roles inserted: $grants new (existing rows unchanged)"

total_grants=$(run_pg zorbit_authorization "SELECT COUNT(*) FROM user_roles WHERE role_hash_id='R-SADMIN';" | tail -1 | tr -d ' ')

declared_count=$(jq '.super_admins | length' "$SA_JSON")
{
  printf '{"phase":"seed-super-admins","env":"%s","declared":%s,"register_out":"%s","users_role_set":%s,"r_sadmin_grants_total":%s,"result":"%s"}\n' \
    "$ENV_PREFIX" "$declared_count" "$register_out" "$roles_set" "$total_grants" \
    "$([[ $total_grants -ge 1 && $roles_set -ge 1 ]] && echo pass || echo fail)"
} > "${REPORT_DIR}/seed-super-admins.json" || true

if (( total_grants < 1 || roles_set < 1 )); then
  echo "==> D5+D6 FAILED"
  exit 1
fi
echo "==> D5+D6 PASS  (users.role set: $roles_set, R-SADMIN grants: $total_grants)"
