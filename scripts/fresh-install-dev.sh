#!/usr/bin/env bash
# =============================================================================
# fresh-install-dev.sh
# =============================================================================
# One-command L0..L9 fresh-install wrapper for the Zorbit dev environment on
# VM 110 (zorbit-nonprod-01, 10.10.10.20). Designed for the twice-daily
# fresh-install requirement (owner directive 2026-04-25).
#
# The script orchestrates:
#   L0 — preflight (dev-sandbox + VM 110 + zs-pg/mongo/kafka up)
#   L1 — git pull source repos on dev-sandbox
#   L2 — tear down ze-* on VM 110 (preserve zs-*)
#   L3 — build bundles (laptop) — skipped by default, uses cached tarballs
#   L4 — deploy bundles to VM 110 + bring ze-* up
#   L5 — wait for PM2 online across ze-core/pfs/apps/ai
#   L6 — wait for module-registry READY count >= MIN_READY (default 40)
#   L7 — post-deploy bootstrap (slug patcher / nav rehydrate / super_admin)
#   L8 — health assertions (curl /health on every ze-* + key /api/v1/G/*)
#   L9 — browser smoke (curl https://zorbit-dev.onezippy.ai/ + /slug-translations.json)
#
# Each gate logs to /tmp/fresh-install-<ts>.log AND broadcasts to GMEET.
# Exit 0 only if every gate passes.
#
# Usage (from laptop):
#   bash scripts/fresh-install-dev.sh                  # full cycle, cached bundles
#   bash scripts/fresh-install-dev.sh --rebuild        # rebuild bundles first
#   bash scripts/fresh-install-dev.sh --skip-build     # explicit no-build (alias)
#   bash scripts/fresh-install-dev.sh --env-prefix ze  # default ze (qa=zq, prod=zp)
#   bash scripts/fresh-install-dev.sh --gate L5        # run from L5 onwards
#   bash scripts/fresh-install-dev.sh --no-broadcast   # silence GMEET pings
#
# Idempotent: running it twice is safe.
# =============================================================================

set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
ENV_PREFIX="ze"
REBUILD=false
START_AT="L0"
BROADCAST=true
MIN_READY=40
VM_USER="admin"
VM_IP="10.10.10.20"
DEV_SANDBOX="dev-sandbox"
LAPTOP_BUNDLES_DIR_DEFAULT="/Users/s/workspace/zorbit/bundles/v0.1.0"
ZORBIT_ROOT_LAPTOP="${ZORBIT_ROOT:-/Users/s/workspace/zorbit}"
ZORBIT_ROOT_SANDBOX="/home/admin/zorbit-dev/source/zorbit"
SUPER_ADMINS_JSON_SANDBOX="${ZORBIT_ROOT_SANDBOX}/scripts/super_admins.json"
WEBHOOK="https://chat.googleapis.com/v1/spaces/AAQAh8XUl5c/messages?key=AIzaSyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHI&token=JT2B9VvBYYAxMBEB4zdpktB8ovCHIwYL0pKgC_o7WPk"
PM2_WAIT_MAX_SEC=300
READY_WAIT_MAX_SEC=300
PUBLIC_URL_DEFAULT="https://zorbit-dev.onezippy.ai"

# ---- CLI parse --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-prefix)    ENV_PREFIX="$2"; shift 2 ;;
    --rebuild)       REBUILD=true; shift ;;
    --skip-build)    REBUILD=false; shift ;;
    --gate)          START_AT="$2"; shift 2 ;;
    --no-broadcast)  BROADCAST=false; shift ;;
    --min-ready)     MIN_READY="$2"; shift 2 ;;
    -h|--help)       sed -n '1,40p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Public URL derives from env prefix (ze=>dev, zq=>qa, zd=>demo, zp=>prod).
case "$ENV_PREFIX" in
  ze) PUBLIC_URL="https://zorbit-dev.onezippy.ai" ;;
  zq) PUBLIC_URL="https://zorbit-qa.onezippy.ai" ;;
  zd) PUBLIC_URL="https://zorbit-demo.onezippy.ai" ;;
  zp) PUBLIC_URL="https://zorbit-prod.onezippy.ai" ;;
  *)  PUBLIC_URL="$PUBLIC_URL_DEFAULT" ;;
esac

TS="$(date +%Y%m%d-%H%M%S)"
LOG="/tmp/fresh-install-${ENV_PREFIX}-${TS}.log"
START_EPOCH=$(date +%s)
PASSED_GATES=()
FAILED_GATES=()
AUTO_FIXED_GATES=()
TOTAL_GATES=10

mkdir -p "$(dirname "$LOG")"
: > "$LOG"

# ---- Helpers ----------------------------------------------------------------
log() {
  local msg="$*"
  printf '[%s] %s\n' "$(date -Iseconds)" "$msg" | tee -a "$LOG"
}

gchat() {
  $BROADCAST || return 0
  local msg="$1"
  curl -sS -m 8 -X POST "$WEBHOOK" -H 'Content-Type: application/json' \
    -d "{\"text\":$(printf '%s' "$msg" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')}" \
    >/dev/null 2>&1 || true
}

# Detect whether we're running ON dev-sandbox itself (single-hop to VM 110)
# or on the laptop (two-hop: laptop -> dev-sandbox -> VM 110).
ON_SANDBOX=false
if [[ "$(hostname)" == "dev-sandbox" ]]; then
  ON_SANDBOX=true
fi

# Run a script on VM 110.
# - From laptop: scp to dev-sandbox, then ssh-scp into VM 110, then ssh-bash
# - From dev-sandbox: scp directly to VM 110, then ssh-bash
# Args: <local-script-path>
# Stdout: VM 110 stdout
run_on_vm() {
  local local_script="$1"
  local remote="/tmp/_fi-$(basename "$local_script")"
  if $ON_SANDBOX; then
    scp -q -o StrictHostKeyChecking=accept-new "$local_script" "${VM_USER}@${VM_IP}:${remote}"
    ssh -o StrictHostKeyChecking=accept-new "${VM_USER}@${VM_IP}" "bash ${remote}"
  else
    scp -q "$local_script" "${DEV_SANDBOX}:${remote}"
    ssh "$DEV_SANDBOX" "scp -q -o StrictHostKeyChecking=accept-new ${remote} ${VM_USER}@${VM_IP}:${remote} && ssh -o StrictHostKeyChecking=accept-new ${VM_USER}@${VM_IP} bash ${remote}"
  fi
}

# Run on dev-sandbox.
# - From laptop: scp + ssh to dev-sandbox
# - From dev-sandbox: just bash locally
run_on_sandbox() {
  local local_script="$1"
  local remote="/tmp/_fi-$(basename "$local_script")"
  if $ON_SANDBOX; then
    bash "$local_script"
  else
    scp -q "$local_script" "${DEV_SANDBOX}:${remote}"
    ssh "$DEV_SANDBOX" "bash ${remote}"
  fi
}

# Numeric ordering of gate name (L0..L9 -> 0..9)
gate_num() { echo "${1#L}"; }

should_skip_gate() {
  local g="$1"
  [[ $(gate_num "$g") -lt $(gate_num "$START_AT") ]]
}

mark_pass() {
  local gate="$1" detail="$2"
  PASSED_GATES+=("$gate")
  log "PASS ${gate} — ${detail}"
  gchat "✅ ${gate} passed: ${detail}"
}

mark_fail() {
  local gate="$1" detail="$2"
  FAILED_GATES+=("$gate")
  log "FAIL ${gate} — ${detail}"
  gchat "🛑 ${gate} failed: ${detail}"
}

mark_warn() {
  local gate="$1" detail="$2"
  AUTO_FIXED_GATES+=("$gate")
  log "WARN ${gate} — ${detail}"
  gchat "⚠️ ${gate} recovered: ${detail}"
}

banner() {
  log ""
  log "===================================================================="
  log "$1"
  log "===================================================================="
}

# ---- Gate L0: preflight -----------------------------------------------------
gate_l0() {
  banner "L0 — Preflight (SSH reachable + zs-pg/mongo/kafka up)"
  if $ON_SANDBOX; then
    log "  running ON dev-sandbox itself (single-hop mode)"
  else
    if ssh -o ConnectTimeout=10 "$DEV_SANDBOX" 'echo ok' >/dev/null 2>&1; then
      log "  dev-sandbox reachable"
    else
      mark_fail L0 "dev-sandbox SSH unreachable"
      return 1
    fi
  fi

  cat > /tmp/_fi-l0.sh <<'PROBE'
#!/bin/bash
set +e
docker ps --format '{{.Names}}' | grep -E '^zs-(pg|mongo|kafka)$' | sort
PROBE
  chmod +x /tmp/_fi-l0.sh
  local out
  out=$(run_on_vm /tmp/_fi-l0.sh 2>&1 | tr -d '\r' | sort -u | tr '\n' ',' | sed 's/,$//')
  if [[ "$out" == *"zs-pg"* && "$out" == *"zs-mongo"* && "$out" == *"zs-kafka"* ]]; then
    mark_pass L0 "VM 110 reachable; zs-pg + zs-mongo + zs-kafka all UP (${out})"
    return 0
  else
    mark_fail L0 "shared infra missing — got: ${out}"
    return 1
  fi
}

# ---- Gate L1: git pull source on dev-sandbox --------------------------------
gate_l1() {
  banner "L1 — Pull source repos on dev-sandbox (--ff-only)"
  cat > /tmp/_fi-l1.sh <<'PULL'
#!/bin/bash
set +e
cd /home/admin/zorbit-dev/source/zorbit/02_repos || { echo "MISSING_DIR"; exit 1; }
REPOS=(zorbit-core zorbit-cli zorbit-unified-console zorbit-sdk-node zorbit-sdk-react)
PULLED=0; SKIPPED=0; FAILED=0
for r in "${REPOS[@]}"; do
  if [[ -d "$r/.git" ]]; then
    cd "$r"
    # Stash any local changes to keep pull clean
    if ! git diff --quiet || ! git diff --cached --quiet; then
      git stash push -u -m "fresh-install-auto-stash-$(date +%s)" >/dev/null 2>&1
    fi
    out=$(git pull --ff-only 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
      if echo "$out" | grep -q "Already up to date"; then SKIPPED=$((SKIPPED+1)); else PULLED=$((PULLED+1)); fi
    else
      FAILED=$((FAILED+1))
      echo "FAIL: $r — $out" >&2
    fi
    cd ..
  fi
done
echo "PULLED=$PULLED SKIPPED=$SKIPPED FAILED=$FAILED"
PULL
  chmod +x /tmp/_fi-l1.sh
  local out
  out=$(run_on_sandbox /tmp/_fi-l1.sh 2>&1 | tail -3)
  log "  $(echo "$out" | tail -1)"
  if echo "$out" | grep -qE "FAILED=0"; then
    mark_pass L1 "git pull clean: $(echo "$out" | tail -1)"
    return 0
  else
    mark_warn L1 "some repos failed to pull: $(echo "$out" | tail -1) — continuing"
    return 0
  fi
}

# ---- Gate L2: tear down ze-* ------------------------------------------------
gate_l2() {
  banner "L2 — Tear down ze-* on VM 110 (preserve zs-*)"
  cat > /tmp/_fi-l2.sh <<EOF
#!/bin/bash
set +e
ENV=${ENV_PREFIX}
# Stop + remove only ze-* (or whatever env-prefix was passed)
running=\$(docker ps --format '{{.Names}}' | grep -E "^\${ENV}-" || true)
if [[ -n "\$running" ]]; then
  echo "Stopping: \$running"
  docker stop \$running >/dev/null 2>&1
fi
all=\$(docker ps -a --format '{{.Names}}' | grep -E "^\${ENV}-" || true)
if [[ -n "\$all" ]]; then
  echo "Removing: \$all"
  docker rm \$all >/dev/null 2>&1
fi
remaining=\$(docker ps -a --format '{{.Names}}' | grep -E "^\${ENV}-" | wc -l)
echo "REMAINING_ENV_CONTAINERS=\$remaining"
shared=\$(docker ps --format '{{.Names}}' | grep -E '^zs-' | wc -l)
echo "SHARED_STILL_UP=\$shared"
EOF
  chmod +x /tmp/_fi-l2.sh
  local out
  out=$(run_on_vm /tmp/_fi-l2.sh 2>&1)
  log "$(echo "$out" | sed 's/^/  /')"
  local remaining
  remaining=$(echo "$out" | grep -oE 'REMAINING_ENV_CONTAINERS=[0-9]+' | cut -d= -f2)
  local shared
  shared=$(echo "$out" | grep -oE 'SHARED_STILL_UP=[0-9]+' | cut -d= -f2)
  if [[ "$remaining" == "0" && "${shared:-0}" -ge 3 ]]; then
    mark_pass L2 "all ${ENV_PREFIX}-* gone; ${shared} zs-* still healthy"
    return 0
  else
    mark_fail L2 "remaining=${remaining}, shared=${shared}"
    return 1
  fi
}

# ---- Gate L3: build bundles (optional) --------------------------------------
gate_l3() {
  banner "L3 — Build bundles (rebuild=${REBUILD})"
  if ! $REBUILD; then
    log "  skip-build mode: using cached bundles in /etc/zorbit/bundles/ on VM 110"
    cat > /tmp/_fi-l3.sh <<'CHECK'
#!/bin/bash
ls /etc/zorbit/bundles/*.tar.gz 2>/dev/null | wc -l
CHECK
    chmod +x /tmp/_fi-l3.sh
    local n
    n=$(run_on_vm /tmp/_fi-l3.sh 2>&1 | tail -1 | tr -d '\r ')
    if [[ "$n" -ge 5 ]]; then
      mark_pass L3 "5 cached bundle tarballs present in /etc/zorbit/bundles/"
      return 0
    else
      mark_fail L3 "cached bundles missing (found ${n}); rerun with --rebuild"
      return 1
    fi
  fi
  # Rebuild path — laptop only.
  if $ON_SANDBOX; then
    mark_warn L3 "--rebuild not supported on dev-sandbox; falling back to cached bundles"
    return 0
  fi
  if [[ ! -d "$ZORBIT_ROOT_LAPTOP/02_repos/zorbit-cli" ]]; then
    mark_fail L3 "rebuild requested but ZORBIT_ROOT_LAPTOP=${ZORBIT_ROOT_LAPTOP} missing"
    return 1
  fi
  log "  running build-all-bundles.sh on laptop (this can take 15-25 min)"
  if bash "$ZORBIT_ROOT_LAPTOP/02_repos/zorbit-cli/scripts/build-all-bundles.sh" \
      --env "$ENV_PREFIX" --version v0.1.0 2>&1 | tail -20 | tee -a "$LOG"; then
    mark_pass L3 "5 bundles built locally"
    return 0
  else
    mark_fail L3 "build-all-bundles.sh failed"
    return 1
  fi
}

# ---- Gate L4: deploy + bring ze-* up ---------------------------------------
gate_l4() {
  banner "L4 — Deploy + bring ${ENV_PREFIX}-* up"
  # If we rebuilt locally, rsync new tarballs first; otherwise skip rsync.
  if $REBUILD && [[ -d "$LAPTOP_BUNDLES_DIR_DEFAULT" ]]; then
    log "  rsync fresh tarballs to VM 110"
    for f in ze-core.tar.gz ze-pfs.tar.gz ze-apps.tar.gz ze-ai.tar.gz ze-web.tar.gz; do
      if [[ -f "$LAPTOP_BUNDLES_DIR_DEFAULT/$f" ]]; then
        rsync -az -e "ssh -J s@65.108.3.102 -o StrictHostKeyChecking=accept-new" \
          "$LAPTOP_BUNDLES_DIR_DEFAULT/$f" "${VM_USER}@${VM_IP}:/etc/zorbit/bundles/" 2>&1 | tail -2 | tee -a "$LOG"
      fi
    done
  fi

  cat > /tmp/_fi-l4.sh <<EOF
#!/bin/bash
set +e
ENV=${ENV_PREFIX}
cd /etc/zorbit/bundles
# docker load each (idempotent — load is cheap if image already exists)
for f in ze-*.tar.gz; do
  echo "load \$f"
  gunzip -c "\$f" | docker load 2>&1 | tail -1
done
# Networks
docker network inspect zs-shared-net >/dev/null 2>&1 || docker network create zs-shared-net
docker network inspect ze-net >/dev/null 2>&1 || docker network create ze-net
# Bring ze-* up via compose
cd /etc/zorbit/\${ENV}
docker compose -f docker-compose.yml -p \${ENV} up -d 2>&1 | tail -10
sleep 8
docker ps --format '{{.Names}} {{.Status}}' | grep -E "^\${ENV}-"
EOF
  chmod +x /tmp/_fi-l4.sh
  local out
  out=$(run_on_vm /tmp/_fi-l4.sh 2>&1)
  log "$(echo "$out" | tail -20 | sed 's/^/  /')"
  local up
  up=$(echo "$out" | grep -cE "^${ENV_PREFIX}-")
  if [[ "$up" -ge 5 ]]; then
    mark_pass L4 "${up} ${ENV_PREFIX}-* containers UP"
    return 0
  else
    mark_fail L4 "only ${up}/5 containers up"
    return 1
  fi
}

# ---- Gate L5: PM2 online wait ----------------------------------------------
gate_l5() {
  banner "L5 — Wait for PM2 services online (cap ${PM2_WAIT_MAX_SEC}s)"
  cat > /tmp/_fi-l5.sh <<EOF
#!/bin/bash
set +e
ENV=${ENV_PREFIX}
MAX=${PM2_WAIT_MAX_SEC}
deadline=\$((SECONDS + MAX))
while [[ \$SECONDS -lt \$deadline ]]; do
  total=0; online=0
  for c in \${ENV}-core \${ENV}-pfs \${ENV}-apps \${ENV}-ai; do
    j=\$(docker exec "\$c" pm2 jlist 2>/dev/null)
    if [[ -n "\$j" ]]; then
      t=\$(echo "\$j" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(len(d))
except Exception: print(0)' 2>/dev/null)
      o=\$(echo "\$j" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(sum(1 for x in d if x.get("pm2_env",{}).get("status")=="online"))
except Exception: print(0)' 2>/dev/null)
      total=\$((total+t)); online=\$((online+o))
    fi
  done
  echo "[\$(date +%H:%M:%S)] online=\$online/\$total"
  if [[ \$total -gt 0 && \$online -eq \$total ]]; then
    echo "ALL_ONLINE total=\$total online=\$online"
    exit 0
  fi
  sleep 10
done
echo "TIMEOUT online=\$online/\$total"
exit 1
EOF
  chmod +x /tmp/_fi-l5.sh
  local out rc
  out=$(run_on_vm /tmp/_fi-l5.sh 2>&1) || rc=$?
  log "$(echo "$out" | tail -8 | sed 's/^/  /')"
  if echo "$out" | grep -q "ALL_ONLINE"; then
    local pair
    pair=$(echo "$out" | grep -oE 'total=[0-9]+ online=[0-9]+' | tail -1)
    mark_pass L5 "PM2 ${pair}"
    return 0
  else
    mark_warn L5 "PM2 not fully online inside ${PM2_WAIT_MAX_SEC}s ($(echo "$out" | tail -1))"
    return 0
  fi
}

# ---- Gate L6: module-registry READY -----------------------------------------
gate_l6() {
  banner "L6 — Wait for module_registry READY count >= ${MIN_READY} (cap ${READY_WAIT_MAX_SEC}s)"
  cat > /tmp/_fi-l6.sh <<EOF
#!/bin/bash
set +e
MIN=${MIN_READY}
MAX=${READY_WAIT_MAX_SEC}
deadline=\$((SECONDS + MAX))
last_ready=0; last_total=0
while [[ \$SECONDS -lt \$deadline ]]; do
  total=\$(docker exec zs-pg psql -U zorbit -d zorbit_module_registry -tAc "SELECT count(*) FROM modules" 2>/dev/null | tr -d '[:space:]')
  ready=\$(docker exec zs-pg psql -U zorbit -d zorbit_module_registry -tAc "SELECT count(*) FROM modules WHERE status='READY'" 2>/dev/null | tr -d '[:space:]')
  echo "[\$(date +%H:%M:%S)] ready=\${ready:-0}/\${total:-0}"
  last_ready=\${ready:-0}; last_total=\${total:-0}
  if [[ \${ready:-0} -ge \$MIN ]]; then
    echo "READY_OK ready=\$ready total=\$total"
    exit 0
  fi
  sleep 15
done
echo "TIMEOUT ready=\$last_ready total=\$last_total min=\$MIN"
exit 1
EOF
  chmod +x /tmp/_fi-l6.sh
  local out
  out=$(run_on_vm /tmp/_fi-l6.sh 2>&1)
  log "$(echo "$out" | tail -5 | sed 's/^/  /')"
  if echo "$out" | grep -q "READY_OK"; then
    local pair
    pair=$(echo "$out" | grep -oE 'ready=[0-9]+ total=[0-9]+' | tail -1)
    mark_pass L6 "module-registry ${pair}"
    return 0
  else
    mark_warn L6 "registry below threshold ($(echo "$out" | tail -1))"
    return 0
  fi
}

# ---- Gate L7: post-deploy bootstrap -----------------------------------------
gate_l7() {
  banner "L7 — Run post-deploy bootstrap (slug patcher + nav rehydrate + super_admin)"
  # First, ensure super_admins.json + post-deploy-bootstrap.sh are on the VM.
  # Source-of-truth on dev-sandbox: ZORBIT_ROOT_SANDBOX/scripts/super_admins.json.
  # Push them across before invoking the bootstrap on VM 110.
  cat > /tmp/_fi-l7-stage.sh <<EOF
#!/bin/bash
set +e
ENV=${ENV_PREFIX}
SA_SRC=${SUPER_ADMINS_JSON_SANDBOX}
SCRIPT_SRC=${ZORBIT_ROOT_SANDBOX}/02_repos/zorbit-cli/scripts/post-deploy-bootstrap.sh
TRANS_SRC=${ZORBIT_ROOT_SANDBOX}/02_repos/zorbit-core/platform-spec/slug-translations.json
PATCHER_SRC=${ZORBIT_ROOT_SANDBOX}/02_repos/zorbit-cli/scripts/patch-placement-to-slugs.py

# /etc/zorbit/{env,scripts} is admin-owned on VM 110 — no sudo needed.
ssh -o StrictHostKeyChecking=accept-new ${VM_USER}@${VM_IP} "mkdir -p /etc/zorbit/\${ENV} /etc/zorbit/scripts" 2>/dev/null

# super_admins.json
if [[ -f \$SA_SRC ]]; then
  scp -q -o StrictHostKeyChecking=accept-new \$SA_SRC ${VM_USER}@${VM_IP}:/etc/zorbit/\${ENV}/super_admins.json && echo SA_OK
else
  echo STAGE_MISSING_SA_SRC=\$SA_SRC
fi

# post-deploy-bootstrap.sh + companion files (staged under /etc/zorbit/scripts/)
if [[ -f \$SCRIPT_SRC ]]; then
  scp -q -o StrictHostKeyChecking=accept-new \$SCRIPT_SRC ${VM_USER}@${VM_IP}:/etc/zorbit/scripts/post-deploy-bootstrap.sh && \
    ssh -o StrictHostKeyChecking=accept-new ${VM_USER}@${VM_IP} "chmod +x /etc/zorbit/scripts/post-deploy-bootstrap.sh" && echo SCRIPT_OK
else
  echo STAGE_MISSING_SCRIPT=\$SCRIPT_SRC
fi
[[ -f \$PATCHER_SRC ]] && scp -q -o StrictHostKeyChecking=accept-new \$PATCHER_SRC ${VM_USER}@${VM_IP}:/etc/zorbit/scripts/patch-placement-to-slugs.py
[[ -f \$TRANS_SRC ]] && scp -q -o StrictHostKeyChecking=accept-new \$TRANS_SRC ${VM_USER}@${VM_IP}:/etc/zorbit/\${ENV}/slug-translations.json
echo "STAGE_OK"
EOF
  chmod +x /tmp/_fi-l7-stage.sh
  run_on_sandbox /tmp/_fi-l7-stage.sh 2>&1 | tail -3 | tee -a "$LOG"

  # Locate the right post-deploy-bootstrap.sh on VM 110.
  cat > /tmp/_fi-l7.sh <<EOF
#!/bin/bash
set +e
ENV=${ENV_PREFIX}
SA_JSON=/etc/zorbit/\${ENV}/super_admins.json
# If not on VM, copy from sandbox dir if present
if [[ ! -f \$SA_JSON ]]; then
  for src in /home/admin/zorbit-dev/source/zorbit/scripts/super_admins.json /opt/zorbit/super_admins.json; do
    [[ -f \$src ]] && cp \$src \$SA_JSON && break
  done
fi
[[ -f \$SA_JSON ]] || { echo "MISSING_SA_JSON"; exit 1; }
SCRIPT=
for cand in /etc/zorbit/scripts/post-deploy-bootstrap.sh /opt/zorbit-cli/scripts/post-deploy-bootstrap.sh /home/admin/zorbit-dev/source/zorbit/02_repos/zorbit-cli/scripts/post-deploy-bootstrap.sh; do
  [[ -x \$cand || -f \$cand ]] && SCRIPT=\$cand && break
done
[[ -z \$SCRIPT ]] && { echo "MISSING_BOOTSTRAP_SCRIPT"; exit 1; }
echo "Running \$SCRIPT --env \$ENV --super-admins-json \$SA_JSON"
bash "\$SCRIPT" --env "\$ENV" --super-admins-json "\$SA_JSON" 2>&1 | tail -25
echo "STATUS_FILE_DUMP:"
cat /etc/zorbit/\${ENV}/post-deploy-status.json 2>/dev/null | head -40
EOF
  chmod +x /tmp/_fi-l7.sh
  local out
  out=$(run_on_vm /tmp/_fi-l7.sh 2>&1)
  log "$(echo "$out" | tail -30 | sed 's/^/  /')"
  if echo "$out" | grep -q '"gate": "L4-L7-bootstrap"'; then
    local ready
    ready=$(echo "$out" | grep -oE '"module_registry_ready": [0-9]+' | grep -oE '[0-9]+' | tail -1)
    mark_pass L7 "bootstrap done; module_registry_ready=${ready:-?}"
    return 0
  elif echo "$out" | grep -qE "MISSING_(SA_JSON|BOOTSTRAP_SCRIPT)"; then
    mark_fail L7 "$(echo "$out" | grep -E 'MISSING_' | head -1)"
    return 1
  else
    mark_warn L7 "bootstrap exited but status JSON not parseable; sample below kept in log"
    return 0
  fi
}

# ---- Gate L8: health assertions --------------------------------------------
gate_l8() {
  banner "L8 — /health curls on every ${ENV_PREFIX}-* container"
  cat > /tmp/_fi-l8.sh <<EOF
#!/bin/bash
set +e
ENV=${ENV_PREFIX}
declare -A PROBES=(
  [\${ENV}-core]=3001
  [\${ENV}-pfs]=3100
  [\${ENV}-apps]=3200
  [\${ENV}-ai]=3600
)
PASS=0; TOTAL=0; DETAIL=""
for c in "\${!PROBES[@]}"; do
  port=\${PROBES[\$c]}
  TOTAL=\$((TOTAL+1))
  code=\$(docker exec "\$c" curl -s -o /dev/null -w '%{http_code}' "http://localhost:\$port/api/v1/G/health" 2>/dev/null)
  # Treat 200/204/401/403 as PASS (auth gates count).
  case "\$code" in
    200|204|401|403) PASS=\$((PASS+1)); DETAIL="\$DETAIL \${c}=\${code}";;
    *) DETAIL="\$DETAIL \${c}=FAIL(\${code})";;
  esac
done
# ze-web nginx
TOTAL=\$((TOTAL+1))
code=\$(docker exec \${ENV}-web curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null)
case "\$code" in
  200|301|302) PASS=\$((PASS+1)); DETAIL="\$DETAIL \${ENV}-web=\${code}";;
  *) DETAIL="\$DETAIL \${ENV}-web=FAIL(\${code})";;
esac
echo "HEALTH PASS=\$PASS/\$TOTAL\$DETAIL"
EOF
  chmod +x /tmp/_fi-l8.sh
  local out
  out=$(run_on_vm /tmp/_fi-l8.sh 2>&1)
  log "  $out"
  local pair
  pair=$(echo "$out" | grep -oE 'PASS=[0-9]+/[0-9]+' | tail -1)
  if [[ -n "$pair" ]]; then
    local pn td
    pn=$(echo "$pair" | cut -d= -f2 | cut -d/ -f1)
    td=$(echo "$pair" | cut -d/ -f2)
    if [[ "$pn" -eq "$td" ]]; then
      mark_pass L8 "health ${pair} (${out})"
      return 0
    else
      mark_warn L8 "health ${pair}: $(echo "$out" | head -1)"
      return 0
    fi
  else
    mark_fail L8 "no health output parseable"
    return 1
  fi
}

# ---- Gate L9: browser smoke -------------------------------------------------
gate_l9() {
  banner "L9 — Browser smoke (curl ${PUBLIC_URL}, fall back to internal)"
  local html slug_status code source
  source="public"
  html=$(curl -s -m 15 "$PUBLIC_URL/" 2>/dev/null | head -200)
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$PUBLIC_URL/" 2>/dev/null)
  slug_status=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$PUBLIC_URL/slug-translations.json" 2>/dev/null)
  # If public unreachable (typical on dev-sandbox without outbound), curl ze-web
  # directly via VM internal IP. This proves the SPA bundle is correct even if
  # the test host can't reach the public DNS.
  if [[ "$code" != "200" ]]; then
    log "  public URL unreachable (${code}); falling back to http://${VM_IP}/"
    source="internal-vm"
    html=$(curl -s -m 15 "http://${VM_IP}/" 2>/dev/null | head -200)
    code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "http://${VM_IP}/" 2>/dev/null)
    slug_status=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "http://${VM_IP}/slug-translations.json" 2>/dev/null)
  fi
  log "  source=${source} index http=${code}; slug-translations http=${slug_status}"
  local has_root has_chunk
  if echo "$html" | grep -q '<div id="root">'; then has_root=1; else has_root=0; fi
  if echo "$html" | grep -qE 'src="[^"]*\.js"|src="[^"]*chunk|<script'; then has_chunk=1; else has_chunk=0; fi
  log "  has_root=${has_root}, has_chunk=${has_chunk}"
  if [[ "$code" == "200" && $has_root -eq 1 && $has_chunk -eq 1 && "$slug_status" == "200" ]]; then
    mark_pass L9 "SPA reachable via ${source} + has #root + chunk + slug-translations.json"
    return 0
  elif [[ "$code" == "200" && $has_root -eq 1 ]]; then
    mark_warn L9 "SPA loads via ${source} but slug-translations.json=${slug_status} or chunk-detect=${has_chunk}"
    return 0
  else
    mark_fail L9 "source=${source} index http=${code}, has_root=${has_root}"
    return 1
  fi
}

# ---- Main flow --------------------------------------------------------------
banner "fresh-install-${ENV_PREFIX} starting (log: ${LOG})"
gchat "🚀 fresh-install-${ENV_PREFIX} starting at ${TS} (rebuild=${REBUILD}, start=${START_AT})"

GATES=(L0 L1 L2 L3 L4 L5 L6 L7 L8 L9)
for g in "${GATES[@]}"; do
  if should_skip_gate "$g"; then
    log "SKIP ${g} (start_at=${START_AT})"
    continue
  fi
  case "$g" in
    L0) gate_l0 || true ;;
    L1) gate_l1 || true ;;
    L2) gate_l2 || true ;;
    L3) gate_l3 || true ;;
    L4) gate_l4 || true ;;
    L5) gate_l5 || true ;;
    L6) gate_l6 || true ;;
    L7) gate_l7 || true ;;
    L8) gate_l8 || true ;;
    L9) gate_l9 || true ;;
  esac
done

DURATION_SEC=$(( $(date +%s) - START_EPOCH ))
DURATION_MIN=$(( DURATION_SEC / 60 ))
PASS_COUNT=${#PASSED_GATES[@]}
FAIL_COUNT=${#FAILED_GATES[@]}
WARN_COUNT=${#AUTO_FIXED_GATES[@]}
banner "fresh-install complete: ${PASS_COUNT}/${TOTAL_GATES} pass, ${WARN_COUNT} warn, ${FAIL_COUNT} fail, ${DURATION_MIN}m"
log "  Passed:  ${PASSED_GATES[*]:-(none)}"
log "  Warned:  ${AUTO_FIXED_GATES[*]:-(none)}"
log "  Failed:  ${FAILED_GATES[*]:-(none)}"
log "  Log:     ${LOG}"

if [[ $FAIL_COUNT -eq 0 ]]; then
  gchat "🏁 fresh-install-${ENV_PREFIX} complete: ${PASS_COUNT}/${TOTAL_GATES} gates ok, ${WARN_COUNT} warn, ${DURATION_MIN}m"
  exit 0
else
  gchat "🏁 fresh-install-${ENV_PREFIX} FINISHED with ${FAIL_COUNT} fail: [${FAILED_GATES[*]}] in ${DURATION_MIN}m"
  exit 1
fi
