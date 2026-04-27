#!/usr/bin/env bash
# =============================================================================
# scripts/install/seed-authz-roles.sh    [D4]
#
# Defect D4: zq's roles table was empty so R-SADMIN didn't exist; even after
# privileges were seeded, no role linked to them. Result: super-admin login
# returned a JWT with empty role list and SPA refused everything.
#
# This phase ensures:
#   1. R-SADMIN system role exists (org O-DFLT, is_system=true)
#   2. role_privileges_v2 contains R-SADMIN × every-privilege-in-catalog
#
# Idempotent.
#
# Inputs:
#   ENV_PREFIX            REQUIRED
#   ROLES_FILE            default platform-spec/roles-canonical.jsonl
#   PG_CONTAINER          default zs-pg
#   SSH_TARGET            default ''
# =============================================================================
set -euo pipefail

ENV_PREFIX="${ENV_PREFIX:-${1:-}}"
PG_CONTAINER="${PG_CONTAINER:-zs-pg}"
SSH_TARGET="${SSH_TARGET:-}"
REPORT_DIR="${ZORBIT_INSTALL_LOG_DIR:-/var/log/zorbit-install}"
mkdir -p "$REPORT_DIR" 2>/dev/null || REPORT_DIR=/tmp

[[ -z "$ENV_PREFIX" ]] && { echo "ERR: ENV_PREFIX required"; exit 1; }

locate_spec() {
  for cand in \
    "${ROLES_FILE:-}" \
    "/tmp/roles-canonical.jsonl" \
    "/work/zorbit/02_repos/zorbit-core/platform-spec/roles-canonical.jsonl" \
    "/Users/s/workspace/zorbit/02_repos/zorbit-core/platform-spec/roles-canonical.jsonl" \
    "$(dirname "$0")/../../../../zorbit-core/platform-spec/roles-canonical.jsonl"; do
    [[ -n "$cand" && -f "$cand" ]] && { echo "$cand"; return 0; }
  done
  return 1
}

ROLES_FILE="$(locate_spec)" || { echo "ERR: roles-canonical.jsonl not found"; exit 1; }

run_pg() {
  local sql="$1"
  local flags="${2:-}"
  if [[ -n "$SSH_TARGET" ]]; then
    ssh "$SSH_TARGET" "sudo docker exec -i $PG_CONTAINER psql -U zorbit -d zorbit_authorization $flags -v ON_ERROR_STOP=1" <<<"$sql"
  else
    docker exec -i "$PG_CONTAINER" psql -U zorbit -d zorbit_authorization $flags -v ON_ERROR_STOP=1 <<<"$sql"
  fi
}

echo "==> seeding system roles"
role_inserts=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  hid=$(echo "$line" | jq -r .hashId)
  name=$(echo "$line" | jq -r .name | sed "s/'/''/g")
  desc=$(echo "$line" | jq -r .description | sed "s/'/''/g")
  org=$(echo "$line" | jq -r .organization_hash_id)
  sys=$(echo "$line" | jq -r .is_system)
  st=$(echo "$line" | jq -r .status | sed "s/'/''/g")
  role_inserts+="INSERT INTO roles (id, \"hashId\", name, description, organization_hash_id, is_system, status) VALUES (uuid_generate_v4(), '$hid', '$name', '$desc', '$org', $sys, '$st') ON CONFLICT (\"hashId\") DO NOTHING;"$'\n'
done < "$ROLES_FILE"

run_pg "$role_inserts" >/dev/null

# Bind R-SADMIN to every privilege
echo "==> binding R-SADMIN to every privilege in catalogue"
run_pg "
INSERT INTO role_privileges_v2 (id, role_id, privilege_id)
SELECT uuid_generate_v4(), r.id, p.id
FROM roles r CROSS JOIN privileges_v2 p
WHERE r.\"hashId\" = 'R-SADMIN'
ON CONFLICT DO NOTHING;
" >/dev/null

# Verify
roles_count=$(run_pg "SELECT COUNT(*) FROM roles WHERE is_system=true;" "-tA" | tail -1 | tr -d ' ')
sa_priv_count=$(run_pg "SELECT COUNT(*) FROM role_privileges_v2 rp JOIN roles r ON r.id=rp.role_id WHERE r.\"hashId\"='R-SADMIN';" "-tA" | tail -1 | tr -d ' ')
priv_total=$(run_pg "SELECT COUNT(*) FROM privileges_v2;" "-tA" | tail -1 | tr -d ' ')

echo "  system roles: $roles_count"
echo "  R-SADMIN priv links: $sa_priv_count / $priv_total"

{
  printf '{"phase":"seed-authz-roles","env":"%s","system_roles":%s,"r_sadmin_priv_links":%s,"priv_total":%s,"result":"%s"}\n' \
    "$ENV_PREFIX" "$roles_count" "$sa_priv_count" "$priv_total" \
    "$([[ $sa_priv_count -eq $priv_total && $roles_count -ge 1 ]] && echo pass || echo fail)"
} > "${REPORT_DIR}/seed-authz-roles.json" || true

if (( sa_priv_count != priv_total || roles_count < 1 )); then
  echo "==> D4 FAILED"
  exit 1
fi
echo "==> D4 PASS"
