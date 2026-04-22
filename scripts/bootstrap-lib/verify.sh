#!/usr/bin/env bash
# zorbit-cli/scripts/bootstrap-lib/verify.sh
# Final verification: hit /health for every service, print table.
# ---------------------------------------------------------------------------

verify_service_health() {
  local env_name="$1"; local env_file="$2"; local manifest_file="$3"
  local port_base
  port_base=$(python3 - "${env_file}" "${env_name}" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    envs = yaml.safe_load(f)
e = next(x for x in envs['environments'] if x['name'] == sys.argv[2])
print(e['port_base'])
PY
)

  echo ""
  log_step "Service Health Verification"
  print_table_header "Service" "Port" "Health"

  local total=0; local ok=0
  python3 - "${manifest_file}" <<'PY' | while IFS='|' read -r name port; do
import sys, yaml
with open(sys.argv[1]) as f:
    m = yaml.safe_load(f)
for r in m['repos']:
    if r.get('type') == 'service' and r.get('port'):
        print(f"{r['name']}|{r['port']}")
PY
    total=$((total + 1))
    local host_port=$((port_base + port - 3000))
    local status
    if [[ "${DRY_RUN}" == "true" ]]; then
      status="${C_YEL}DRY${C_RESET}"
    elif curl -fsS --max-time 3 "http://127.0.0.1:${host_port}/health" >/dev/null 2>&1; then
      status="${C_GRN}OK${C_RESET}"
      ok=$((ok + 1))
    else
      status="${C_RED}DOWN${C_RESET}"
    fi
    print_table_row "${name}" "${host_port}" "${status}"
  done

  echo ""
  log_info "${ok} of ${total} services healthy"
}

register_modules_via_kafka() {
  local env_name="$1"; local manifest_file="$2"
  log_info "Module registry announcement (Kafka HMAC-signed)..."
  # For MVP: delegate to a per-service init script that already publishes
  # module.registry.announce events on startup. This function is a hook.
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY: would announce every module to module-registry via Kafka"
    return 0
  fi
  # Each service publishes its own announce event on boot — trust that path.
  log_ok "Services will self-announce on boot (module-registry consumes)"
}

verify_modules_ready() {
  local port_base="$1"
  local module_registry_port=$((port_base + 20))
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY: would GET http://127.0.0.1:${module_registry_port}/api/v1/G/modules"
    return 0
  fi
  if curl -fsS "http://127.0.0.1:${module_registry_port}/api/v1/G/modules" 2>/dev/null \
     | python3 -c "import sys,json; d=json.load(sys.stdin); print('Modules READY:', sum(1 for m in d.get('data',[]) if m.get('status')=='READY'))"; then
    log_ok "Module registry responded"
  else
    log_warn "Could not reach module registry — check manually"
  fi
}

print_next_steps() {
  local env_name="$1"; local hostname="$2"
  cat <<NEXT

  Next steps:
    1. Install nginx config (requires sudo — see instructions above)
    2. Test: curl -I https://${hostname}/
    3. Run smoke test:  zorbit-cli/scripts/smoke-test.sh --env ${env_name}
    4. Promote to next tier: zorbit-cli/scripts/promote-env.sh --from ${env_name} --to <next>
    5. Monitor: docker compose -f /opt/zorbit-platform/${env_name}/docker-compose.yml logs -f

NEXT
}
