#!/usr/bin/env bash
# =============================================================================
# scripts/install/register-all-modules.sh    [D7]
#
# Defect D7: zq's module_registry had only 20 of the 67 modules registered.
# Modules normally announce themselves via Kafka on boot — but that path
# silently fails when (a) the service crash-loops before announcing,
# (b) Kafka isn't ready when the service comes up, (c) HMAC mismatch.
#
# This phase POSTs every static manifest in 02_repos/* directly to the
# module_registry HTTP API as a deterministic, idempotent backstop. Even
# if a service is down, its manifest is registered — the service can
# transition status:READY when it comes online.
#
# Inputs:
#   ENV_PREFIX               REQUIRED
#   PUBLIC_URL               default https://zorbit-${ENV_PREFIX}.onezippy.ai
#   ADMIN_JWT                REQUIRED (for registry.module.admin privilege)
#   REPOS_DIR                default /work/zorbit/02_repos (or /Users/s/workspace/zorbit/02_repos)
#   SSH_TARGET               default '' (used for endpoint reachability if local can't)
# =============================================================================
set -euo pipefail

ENV_PREFIX="${ENV_PREFIX:-${1:-}}"
PUBLIC_URL="${PUBLIC_URL:-https://zorbit-${ENV_PREFIX}.onezippy.ai}"
ADMIN_JWT="${ADMIN_JWT:-}"
REPOS_DIR="${REPOS_DIR:-}"
SSH_TARGET="${SSH_TARGET:-}"
REPORT_DIR="${ZORBIT_INSTALL_LOG_DIR:-/var/log/zorbit-install}"
mkdir -p "$REPORT_DIR" 2>/dev/null || REPORT_DIR=/tmp

[[ -z "$ENV_PREFIX" ]] && { echo "ERR: ENV_PREFIX required"; exit 1; }
[[ -z "$ADMIN_JWT" ]] && { echo "ERR: ADMIN_JWT required (super-admin token)"; exit 1; }

# locate repos dir
if [[ -z "$REPOS_DIR" ]]; then
  for c in /work/zorbit/02_repos /Users/s/workspace/zorbit/02_repos; do
    [[ -d "$c" ]] && REPOS_DIR="$c" && break
  done
fi
[[ ! -d "$REPOS_DIR" ]] && { echo "ERR: REPOS_DIR not found"; exit 1; }

# Find all manifests
manifests=()
while IFS= read -r f; do
  manifests+=("$f")
done < <(find "$REPOS_DIR" -maxdepth 3 -name "zorbit-module-manifest.json" 2>/dev/null | sort)

echo "==> registering ${#manifests[@]} manifests against $PUBLIC_URL"

ok=0; existed=0; failed=0; failed_ids=""
for m in "${manifests[@]}"; do
  mid=$(jq -r .moduleId "$m" 2>/dev/null || echo "")
  [[ -z "$mid" || "$mid" == "null" ]] && { echo "  SKIP (no moduleId): $m"; continue; }
  # post directly with full manifest
  resp=$(curl -sS -m 30 -o /tmp/_reg-resp.json -w '%{http_code}' \
    -X POST "${PUBLIC_URL}/api/module_registry/api/v1/G/modules" \
    -H "Authorization: Bearer ${ADMIN_JWT}" \
    -H 'Content-Type: application/json' \
    --data "@${m}" 2>/dev/null || echo "000")
  case "$resp" in
    201|200)
      ok=$((ok+1))
      printf '  ok   %s\n' "$mid"
      ;;
    409)
      existed=$((existed+1))
      printf '  exist %s\n' "$mid"
      ;;
    *)
      failed=$((failed+1))
      failed_ids+="$mid:$resp "
      err=$(head -c 200 /tmp/_reg-resp.json 2>/dev/null || echo "")
      printf '  FAIL %s code=%s msg=%s\n' "$mid" "$resp" "$err"
      ;;
  esac
done

echo
echo "==> register-all-modules: ok=$ok existed=$existed failed=$failed"

# verify in DB if zs-pg reachable
total=""
if [[ -n "$SSH_TARGET" ]]; then
  total=$(ssh "$SSH_TARGET" "sudo docker exec zs-pg psql -U zorbit -d zorbit_module_registry -tAc 'SELECT COUNT(*) FROM modules'" 2>/dev/null | tail -1 | tr -d ' ' || echo "")
fi

{
  printf '{"phase":"register-all-modules","env":"%s","manifests_found":%s,"ok":%s,"existed":%s,"failed":%s,"failed_ids":"%s","registry_total":"%s","result":"%s"}\n' \
    "$ENV_PREFIX" "${#manifests[@]}" "$ok" "$existed" "$failed" "$failed_ids" "$total" \
    "$([[ $failed -eq 0 ]] && echo pass || echo fail)"
} > "${REPORT_DIR}/register-all-modules.json" || true

if (( failed > 0 )); then
  echo "==> D7 FAILED ($failed manifests rejected) — see report"
  exit 1
fi
echo "==> D7 PASS"
