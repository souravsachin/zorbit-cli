#!/usr/bin/env bash
# zorbit-cli/scripts/bootstrap-lib/services.sh
# Clone, build, and start Zorbit services.
# ---------------------------------------------------------------------------

clone_all_repos() {
  local remote_base="$1"; local manifest_file="$2"; local dest_root="$3"
  mkdir -p "${dest_root}" 2>/dev/null || true
  local repos
  repos=$(python3 - "${manifest_file}" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
for r in data['repos']:
    print(r['name'])
PY
)
  local repo
  for repo in ${repos}; do
    local target="${dest_root}/${repo}"
    if [[ -d "${target}/.git" ]]; then
      run_cmd "Pull ${repo}" git -C "${target}" pull --ff-only
    else
      run_cmd "Clone ${repo}" git clone "${remote_base}/${repo}.git" "${target}"
    fi
  done
}

build_base_image() {
  # zorbit-pm2-base:1.0 — shared image for services needing chromium
  local dockerfile
  dockerfile="$(dirname "${BASH_SOURCE[0]}")/../templates/Dockerfile.pm2-base"
  if [[ ! -f "${dockerfile}" ]]; then
    log_warn "Base Dockerfile not found at ${dockerfile} — skipping"
    return 0
  fi
  run_cmd "Build zorbit-pm2-base:1.0" docker build -t zorbit-pm2-base:1.0 -f "${dockerfile}" "$(dirname "${dockerfile}")"
}

build_service_repos() {
  local manifest_file="$1"; local dest_root="$2"
  local repos
  repos=$(python3 - "${manifest_file}" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
for r in data['repos']:
    if r.get('build') == 'npm':
        print(r['name'])
PY
)
  local repo
  for repo in ${repos}; do
    local target="${dest_root}/${repo}"
    if [[ ! -f "${target}/package.json" ]]; then
      log_warn "${repo}: no package.json — skipping"
      continue
    fi
    run_shell "npm ci in ${repo}" "cd '${target}' && npm ci --no-audit --no-fund"
    if python3 -c "
import json,sys
with open('${target}/package.json') as f: p=json.load(f)
sys.exit(0 if 'build' in p.get('scripts',{}) else 1)
" 2>/dev/null; then
      run_shell "npm run build in ${repo}" "cd '${target}' && npm run build"
    fi
  done
}

generate_compose_file() {
  local env_name="$1"; local env_file="$2"; local manifest_file="$3"; local out_file="$4"
  python3 - "${env_file}" "${manifest_file}" "${env_name}" "${out_file}" <<'PY'
import sys, yaml, json
env_file, manifest_file, env_name, out_file = sys.argv[1:5]
with open(env_file) as f:
    envs = yaml.safe_load(f)
with open(manifest_file) as f:
    manifest = yaml.safe_load(f)

env = next(e for e in envs['environments'] if e['name'] == env_name)
prefix = env['container_prefix']
port_base = env['port_base']

compose = {
    "version": "3.8",
    "networks": {f"{prefix}-net": {"driver": "bridge"}},
    "volumes": {},
    "services": {},
}

# Shared infra — per owner rule 2026-04-23, containers shared across
# non-prod environments keep the `zs-` prefix (s = Shared). Do NOT
# rewrite `zs-` to the env prefix. Prod will eventually use dedicated
# `zp-` instances declared separately.
for infra in manifest['infrastructure']:
    name = infra['name']  # keep zs- prefix as-is for shared infra
    svc = {
        "image": infra['image'],
        "container_name": name,
        "restart": "unless-stopped",
        "networks": [f"{prefix}-net"],
    }
    if 'volumes' in infra:
        svc['volumes'] = infra['volumes']
        for v in infra['volumes']:
            vol = v.split(':')[0]
            compose['volumes'][vol] = {}
    compose['services'][name] = svc

# Service repos
for i, r in enumerate(manifest['repos']):
    if r.get('type') != 'service' or not r.get('port'):
        continue
    host_port = port_base + (r['port'] - 3000)
    compose['services'][r['name']] = {
        "build": f"./{r['name']}",
        "container_name": f"{prefix}-{r['name'].replace('zorbit-', '')}",
        "restart": "unless-stopped",
        "networks": [f"{prefix}-net"],
        "ports": [f"{host_port}:{r['port']}"],
        "environment": {
            "NODE_ENV": env_name,
            "PORT": r['port'],
        },
    }

with open(out_file, 'w') as f:
    yaml.dump(compose, f, sort_keys=False, default_flow_style=False)

print(f"Wrote {out_file} with {len(compose['services'])} services")
PY
}

compose_up() {
  local compose_file="$1"
  run_cmd "docker compose up -d" docker compose -f "${compose_file}" up -d
}

wait_services_healthy() {
  local compose_file="$1"; local timeout_s="${2:-180}"
  [[ "${DRY_RUN}" == "true" ]] && { log_info "DRY: would wait for services healthy"; return 0; }
  log_info "Waiting up to ${timeout_s}s for all services to be healthy..."
  local elapsed=0
  while [[ ${elapsed} -lt ${timeout_s} ]]; do
    local unhealthy
    unhealthy=$(docker compose -f "${compose_file}" ps --format json 2>/dev/null \
      | python3 -c "
import sys, json
count = 0
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        if d.get('State') not in ('running',):
            count += 1
    except Exception:
        pass
print(count)
" 2>/dev/null || echo "0")
    if [[ "${unhealthy}" == "0" ]]; then
      log_ok "All services running"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  log_warn "Timed out waiting for services (continuing anyway)"
  return 1
}
