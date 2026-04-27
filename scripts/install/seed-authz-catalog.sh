#!/usr/bin/env bash
# =============================================================================
# scripts/install/seed-authz-catalog.sh    [D3]
#
# Defect D3: zq's privileges_v2 was empty. The SDK's PrivilegeGuard returned
# 403 for every authenticated request because there was nothing to gate
# against. Identity issued JWTs with privilege_set_hash that referenced
# non-existent privileges.
#
# This phase loads the canonical 250-priv catalogue from
# zorbit-core/platform-spec/privileges-canonical.jsonl into
# zorbit_authorization.privileges_v2 + privilege_sections. Idempotent — uses
# ON CONFLICT DO NOTHING so re-running is safe.
#
# Inputs:
#   ENV_PREFIX                  REQUIRED  e.g. zq
#   PRIVS_FILE                  default platform-spec/privileges-canonical.jsonl
#   SECTIONS_FILE               default platform-spec/privilege-sections-canonical.jsonl
#   PG_CONTAINER                default zs-pg
#   SSH_TARGET                  default '' (run locally)
# =============================================================================
set -euo pipefail

ENV_PREFIX="${ENV_PREFIX:-${1:-}}"
PG_CONTAINER="${PG_CONTAINER:-zs-pg}"
SSH_TARGET="${SSH_TARGET:-}"
REPORT_DIR="${ZORBIT_INSTALL_LOG_DIR:-/var/log/zorbit-install}"
mkdir -p "$REPORT_DIR" 2>/dev/null || REPORT_DIR=/tmp

[[ -z "$ENV_PREFIX" ]] && { echo "ERR: ENV_PREFIX required"; exit 1; }

# locate spec files
locate_spec() {
  local name="$1"
  for cand in \
    "${PRIVS_FILE:-}" \
    "/work/zorbit/02_repos/zorbit-core/platform-spec/$name" \
    "/Users/s/workspace/zorbit/02_repos/zorbit-core/platform-spec/$name" \
    "$(dirname "$0")/../../../../zorbit-core/platform-spec/$name" \
    "/etc/zorbit/${ENV_PREFIX}/$name"; do
    [[ -n "$cand" && -f "$cand" ]] && { echo "$cand"; return 0; }
  done
  return 1
}

PRIVS_FILE="$(locate_spec privileges-canonical.jsonl)" || { echo "ERR: privileges-canonical.jsonl not found"; exit 1; }
SECTIONS_FILE="$(locate_spec privilege-sections-canonical.jsonl)" || { echo "ERR: privilege-sections-canonical.jsonl not found"; exit 1; }

run_pg() {
  local sql="$1"
  if [[ -n "$SSH_TARGET" ]]; then
    ssh "$SSH_TARGET" "sudo docker exec -i $PG_CONTAINER psql -U zorbit -d zorbit_authorization -v ON_ERROR_STOP=1" <<<"$sql"
  else
    docker exec -i "$PG_CONTAINER" psql -U zorbit -d zorbit_authorization -v ON_ERROR_STOP=1 <<<"$sql"
  fi
}

# Seed sections first
echo "==> seeding privilege_sections"
sec_inserts=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  id=$(echo "$line" | jq -r .id)
  code=$(echo "$line" | jq -r .section_code)
  lbl=$(echo "$line" | jq -r .section_label | sed "s/'/''/g")
  icon=$(echo "$line" | jq -r .icon | sed "s/'/''/g")
  seq=$(echo "$line" | jq -r .seq_number)
  vis=$(echo "$line" | jq -r .visible)
  sec_inserts+="INSERT INTO privilege_sections (id, section_code, section_label, icon, seq_number, visible) VALUES ('$id', '$code', '$lbl', '$icon', $seq, $vis) ON CONFLICT (section_code) DO NOTHING;"$'\n'
done < "$SECTIONS_FILE"
run_pg "$sec_inserts" >/dev/null
sec_count=$(echo "$sec_inserts" | grep -c '^INSERT' || true)
echo "  seeded $sec_count sections"

# Seed privileges
echo "==> seeding privileges_v2"
priv_count=$(wc -l < "$PRIVS_FILE" | tr -d ' ')
echo "  loading $priv_count privileges"

# Generate one transactional batch — keeps idempotency simple
priv_inserts=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  id=$(echo "$line" | jq -r .id)
  code=$(echo "$line" | jq -r .privilege_code | sed "s/'/''/g")
  lbl=$(echo "$line" | jq -r .privilege_label | sed "s/'/''/g")
  sect=$(echo "$line" | jq -r .section_id)
  icon=$(echo "$line" | jq -r .icon | sed "s/'/''/g")
  vis=$(echo "$line" | jq -r .visible_in_menu)
  seq=$(echo "$line" | jq -r .seq_number)
  priv_inserts+="INSERT INTO privileges_v2 (id, privilege_code, privilege_label, section_id, fe_route_config, be_route_config, icon, visible_in_menu, seq_number) VALUES ('$id', '$code', '$lbl', '$sect', '', '', '$icon', $vis, $seq) ON CONFLICT (privilege_code) DO NOTHING;"$'\n'
done < "$PRIVS_FILE"

# write to a temp file to avoid stdin size limits
tmp=$(mktemp)
echo "$priv_inserts" > "$tmp"
if [[ -n "$SSH_TARGET" ]]; then
  scp -q "$tmp" "$SSH_TARGET:/tmp/zq-priv-seed.sql"
  ssh "$SSH_TARGET" "sudo docker cp /tmp/zq-priv-seed.sql $PG_CONTAINER:/tmp/zq-priv-seed.sql && sudo docker exec $PG_CONTAINER psql -U zorbit -d zorbit_authorization -v ON_ERROR_STOP=1 -f /tmp/zq-priv-seed.sql" >/dev/null
else
  docker cp "$tmp" "$PG_CONTAINER:/tmp/zq-priv-seed.sql"
  docker exec "$PG_CONTAINER" psql -U zorbit -d zorbit_authorization -v ON_ERROR_STOP=1 -f /tmp/zq-priv-seed.sql >/dev/null
fi
rm -f "$tmp"

# Verify count
final=$(run_pg "SELECT COUNT(*) FROM privileges_v2;" | tail -1 | tr -d ' ')
echo "  privileges_v2 row count: $final"

# Report
{
  printf '{"phase":"seed-authz-catalog","env":"%s","sections_seeded":%s,"privileges_loaded":%s,"final_count":%s,"result":"%s"}\n' \
    "$ENV_PREFIX" "$sec_count" "$priv_count" "$final" \
    "$([[ $final -ge $priv_count ]] && echo pass || echo fail)"
} > "${REPORT_DIR}/seed-authz-catalog.json" || true

if (( final < priv_count )); then
  echo "==> D3 FAILED: expected >= $priv_count rows, got $final"
  exit 1
fi
echo "==> D3 PASS"
