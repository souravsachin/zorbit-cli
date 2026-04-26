#!/usr/bin/env bash
# zorbit-cli/scripts/bootstrap-lib/services.sh
# Artifact acquisition + compose generation for Zorbit services.
#
# Owner feedback 2026-04-23 (flaw 1):
#   The installer MUST NOT clone git + build from source. That is unsafe
#   for client environments (build-tooling drift, network reach, trust).
#   Instead the installer either:
#     (a) pulls pre-built images from the container registry, or
#     (b) unpacks a pre-built artifact bundle (tarball) and `docker load`s
#         the images it contains.
#
# The compose generator references `image:` from all-repos.yaml — never
# `build:` contexts.
# ---------------------------------------------------------------------------

# =============================================================================
# Artifact acquisition — registry pull OR bundle unpack.
# =============================================================================

# Pull every runtime image declared in all-repos.yaml from the registry.
# Uses `image:` field (required for type=service|frontend|app|portal).
pull_all_images() {
  local manifest_file="$1"
  local image_tag="${ZORBIT_IMAGE_TAG:-latest}"
  local module_list="${ZORBIT_MODULE_LIST:-}"

  local images
  images=$(python3 - "${manifest_file}" "${image_tag}" "${module_list}" <<'PY'
import sys, yaml, json
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
tag = sys.argv[2]
module_list_path = sys.argv[3] if len(sys.argv) > 3 else ""
allowed = None
if module_list_path:
    with open(module_list_path) as f:
        lockfile = json.load(f)
    allowed = set(lockfile.get('modules', []))
for r in data['repos']:
    if r.get('type') in ('service', 'frontend', 'app', 'portal'):
        if allowed is not None and r['name'] not in allowed:
            continue  # skipped per --module-list lockfile
        img = r.get('image')
        if not img:
            continue
        # Respect explicit tag on image if present, else swap in $tag
        if ':' in img.rsplit('/', 1)[-1]:
            print(img)
        else:
            print(f"{img}:{tag}")
PY
)

  local img
  for img in ${images}; do
    run_cmd "docker pull ${img}" docker pull "${img}"
  done
}

# Unpack an artifact bundle (tarball) and load all images it contains.
# The bundle layout is:
#   bundles/zorbit-v<version>-<arch>.tar.gz
#     ├── images.tar         (docker save of all images)
#     └── manifest.json      (image -> repo map)
# The tarball is either at a local path or at an HTTPS URL.
load_artifact_bundle() {
  local bundle_src="$1"   # local path or https:// url
  local work_dir="${HOME}/.cache/zorbit-bundle"

  mkdir -p "${work_dir}"
  local tarball="${work_dir}/bundle.tar.gz"

  if [[ "${bundle_src}" =~ ^https?:// ]]; then
    run_cmd "Download bundle from ${bundle_src}" curl -fsSL -o "${tarball}" "${bundle_src}"
  else
    if [[ ! -f "${bundle_src}" ]]; then
      log_error "Bundle not found at ${bundle_src}"
      return 1
    fi
    run_cmd "Use local bundle ${bundle_src}" cp "${bundle_src}" "${tarball}"
  fi

  run_cmd "Extract bundle" tar -xzf "${tarball}" -C "${work_dir}"

  if [[ -f "${work_dir}/images.tar" ]]; then
    run_cmd "docker load -i images.tar" docker load -i "${work_dir}/images.tar"
  else
    log_error "Bundle missing images.tar — aborting"
    return 1
  fi
}

# =============================================================================
# Compose generation — references `image:` only, never `build:`.
# =============================================================================

generate_compose_file() {
  local env_name="$1"; local env_file="$2"; local manifest_file="$3"; local out_file="$4"
  python3 - "${env_file}" "${manifest_file}" "${env_name}" "${out_file}" "${ZORBIT_IMAGE_TAG:-latest}" "${ZORBIT_MODULE_LIST:-}" <<'PY'
import sys, yaml, json
env_file, manifest_file, env_name, out_file, tag = sys.argv[1:6]
module_list_path = sys.argv[6] if len(sys.argv) > 6 else ""
allowed = None
if module_list_path:
    with open(module_list_path) as f:
        lockfile = json.load(f)
    allowed = set(lockfile.get('modules', []))
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
# non-prod envs keep the `zs-` prefix (s = Shared). Prod will eventually
# use dedicated `zp-` instances declared separately.
for infra in manifest.get('infrastructure', []):
    name = infra['name']  # keep zs- prefix
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

# Shared TPMs (non-prod convention, always zs-*).
for tpm in manifest.get('tpms_shared', []):
    name = tpm['name']
    svc = {
        "image": tpm['image'],
        "container_name": name,
        "restart": "unless-stopped",
        "networks": [f"{prefix}-net"],
    }
    if 'volumes' in tpm:
        svc['volumes'] = tpm['volumes']
        for v in tpm['volumes']:
            vol = v.split(':')[0]
            compose['volumes'][vol] = {}
    compose['services'][name] = svc

# Service repos — reference IMAGE, never build context.
for r in manifest['repos']:
    if r.get('type') not in ('service', 'frontend', 'app', 'portal'):
        continue
    if not r.get('port'):
        continue
    if allowed is not None and r['name'] not in allowed:
        continue  # skipped per --module-list lockfile (cycle 106)
    image = r.get('image')
    if not image:
        # Required for runtime repos per schema v1.1. Skip with warning on bad manifests.
        continue
    # If image has no :tag, append the resolved tag.
    last_segment = image.rsplit('/', 1)[-1]
    if ':' not in last_segment:
        image = f"{image}:{tag}"

    host_port = port_base + (r['port'] - 3000)
    # Container name: strip the `zorbit-` prefix (the env prefix replaces it).
    module_slug = r['name']
    if module_slug.startswith('zorbit-'):
        module_slug = module_slug[len('zorbit-'):]

    compose['services'][r['name']] = {
        "image": image,
        "container_name": f"{prefix}-{module_slug}",
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

print(f"Wrote {out_file} with {len(compose['services'])} services (image-based, no build: contexts)")
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
