#!/usr/bin/env bash
# =============================================================================
# zorbit-cli/scripts/package-bundle.sh
# =============================================================================
# Produces a self-contained artifact bundle for ONE (env, bundle) pair.
#
# Output:
#   /Users/s/workspace/zorbit/bundles/<version>/<env>-<bundle>.tar.gz
#     ├── images.tar        (docker save of the built bundle image)
#     └── manifest.json     (metadata: env, bundle, version, images[], services[])
#
# The tarball layout matches exactly what bootstrap-lib/services.sh
# `load_artifact_bundle()` expects (images.tar + manifest.json).
#
# LAPTOP-LOCAL ONLY. This script:
#   - DOES use `docker buildx build` and `docker save`.
#   - DOES NOT `docker push` anywhere.
#   - DOES NOT ssh to any server.
#
# Usage:
#   bash scripts/package-bundle.sh \
#        --env ze \
#        --bundle core \
#        --version v0.1.0 \
#        [--platform linux/amd64] \
#        [--skip-build]   # if the image already exists locally
#
# Exit codes:
#   0 = bundle produced
#   1 = arg / environment error
#   2 = docker build failure
#   3 = docker save failure
# =============================================================================

set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
ENV_PREFIX=""
BUNDLE=""
VERSION=""
PLATFORM="linux/amd64"
SKIP_BUILD="false"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/../.." && pwd)"
BUNDLES_DIR="${WORKSPACE_ROOT}/bundles"
BUNDLES_YAML="${WORKSPACE_ROOT}/02_repos/zorbit-core/platform-spec/bundles.yaml"
TEMPLATES_DIR="${REPO_ROOT}/scripts/templates"

# ---- Arg parsing ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)      ENV_PREFIX="$2"; shift 2 ;;
    --bundle)   BUNDLE="$2"; shift 2 ;;
    --version)  VERSION="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD="true"; shift ;;
    -h|--help)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---- Validate ---------------------------------------------------------------
[[ -z "${ENV_PREFIX}" ]] && { echo "ERROR: --env required (ze|zq|zd|zu|zp)" >&2; exit 1; }
[[ -z "${BUNDLE}"     ]] && { echo "ERROR: --bundle required (core|pfs|apps|ai|web)" >&2; exit 1; }
[[ -z "${VERSION}"    ]] && { echo "ERROR: --version required (e.g. v0.1.0)" >&2; exit 1; }

case "${ENV_PREFIX}" in
  ze|zq|zd|zu|zp) : ;;
  *) echo "ERROR: --env must be one of ze|zq|zd|zu|zp" >&2; exit 1 ;;
esac
case "${BUNDLE}" in
  core|pfs|apps|ai|web) : ;;
  *) echo "ERROR: --bundle must be one of core|pfs|apps|ai|web" >&2; exit 1 ;;
esac

if [[ ! -f "${BUNDLES_YAML}" ]]; then
  echo "ERROR: bundles.yaml not found at ${BUNDLES_YAML}" >&2
  exit 1
fi

# ---- Log helpers ------------------------------------------------------------
log()  { printf "[package-bundle] %s\n" "$*"; }
die()  { printf "[package-bundle] ERROR: %s\n" "$*" >&2; exit "${2:-1}"; }

# ---- Derive names -----------------------------------------------------------
IMAGE_NAME="zorbit-${BUNDLE}"
IMAGE_TAG="${VERSION}"
IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"
CONTAINER_NAME="${ENV_PREFIX}-${BUNDLE}"

OUT_DIR="${BUNDLES_DIR}/${VERSION}"
OUT_TARBALL="${OUT_DIR}/${ENV_PREFIX}-${BUNDLE}.tar.gz"
WORK_DIR="$(mktemp -d -t zorbit-pkg-${ENV_PREFIX}-${BUNDLE}-XXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

mkdir -p "${OUT_DIR}"

log "Env:        ${ENV_PREFIX}"
log "Bundle:     ${BUNDLE}"
log "Version:    ${VERSION}"
log "Platform:   ${PLATFORM}"
log "Image:      ${IMAGE_REF}"
log "Container:  ${CONTAINER_NAME}"
log "Output:     ${OUT_TARBALL}"
log "Work dir:   ${WORK_DIR}"

# ---- Read bundle services from bundles.yaml --------------------------------
#
# We parse bundles.yaml with a small Python block and emit:
#   - services JSON list (repo, port, slug) for manifest.json
#   - a newline-delimited list for the Dockerfile COPY pattern
SERVICES_JSON="$(python3 - "${BUNDLES_YAML}" "${BUNDLE}" <<'PY'
import sys, json, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
bundle = data["bundles"][sys.argv[2]]
out = {
    "port_range": bundle["port_range"],
    "runtime":    bundle["runtime"],
    "base_image": bundle["base_image"],
    "services":   bundle["services"],
}
print(json.dumps(out))
PY
)"
[[ -z "${SERVICES_JSON}" ]] && die "Could not read bundle '${BUNDLE}' from ${BUNDLES_YAML}" 1

# ---- Choose Dockerfile template --------------------------------------------
DOCKERFILE_TEMPLATE="${TEMPLATES_DIR}/Dockerfile.${BUNDLE}.j2"
if [[ ! -f "${DOCKERFILE_TEMPLATE}" ]]; then
  die "No Dockerfile template found at ${DOCKERFILE_TEMPLATE}" 1
fi

# ---- Render Dockerfile (trivial {{var}} substitution, not full jinja) ------
#
# Only substitutes a handful of placeholders; enough for our needs.
RENDERED_DOCKERFILE="${WORK_DIR}/Dockerfile"
python3 - "${DOCKERFILE_TEMPLATE}" "${RENDERED_DOCKERFILE}" "${BUNDLE}" \
             "${VERSION}" "${ENV_PREFIX}" <<'PY'
import sys, json, yaml, re
tpl_path, out_path, bundle, version, env_prefix = sys.argv[1:6]
with open(tpl_path) as f:
    tpl = f.read()
ctx = {
    "BUNDLE": bundle,
    "VERSION": version,
    "ENV_PREFIX": env_prefix,
    "CONTAINER_NAME": f"{env_prefix}-{bundle}",
}
def sub(m):
    key = m.group(1).strip()
    return str(ctx.get(key, m.group(0)))
rendered = re.sub(r"\{\{\s*([A-Z_]+)\s*\}\}", sub, tpl)
with open(out_path, "w") as f:
    f.write(rendered)
PY
log "Rendered Dockerfile → ${RENDERED_DOCKERFILE}"

# ---- Build image ------------------------------------------------------------
if [[ "${SKIP_BUILD}" != "true" ]]; then
  log "Building image ${IMAGE_REF} (platform=${PLATFORM})..."
  # Build context = workspace root so that Dockerfile can COPY from 02_repos/*
  if ! docker buildx build \
        --platform "${PLATFORM}" \
        --load \
        -t "${IMAGE_REF}" \
        -f "${RENDERED_DOCKERFILE}" \
        "${WORKSPACE_ROOT}" ; then
    die "docker buildx build failed for ${IMAGE_REF}" 2
  fi
  log "Built ${IMAGE_REF}"
else
  log "--skip-build: assuming ${IMAGE_REF} already present locally"
  if ! docker image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
    die "Image ${IMAGE_REF} not found locally (cannot --skip-build)" 2
  fi
fi

# ---- docker save ------------------------------------------------------------
IMAGES_TAR="${WORK_DIR}/images.tar"
log "Saving image to ${IMAGES_TAR}..."
if ! docker save -o "${IMAGES_TAR}" "${IMAGE_REF}"; then
  die "docker save failed" 3
fi
log "Saved $(du -h "${IMAGES_TAR}" | cut -f1)"

# ---- manifest.json ----------------------------------------------------------
MANIFEST="${WORK_DIR}/manifest.json"
python3 - "${MANIFEST}" "${ENV_PREFIX}" "${BUNDLE}" "${VERSION}" \
             "${IMAGE_REF}" "${CONTAINER_NAME}" "${SERVICES_JSON}" <<'PY'
import sys, json
out, env, bundle, version, image, container, services_json = sys.argv[1:8]
services = json.loads(services_json)
doc = {
    "schema_version": "1.0",
    "env_prefix":     env,
    "bundle":         bundle,
    "version":        version,
    "container_name": container,
    "runtime":        services["runtime"],
    "base_image":     services["base_image"],
    "port_range":     services["port_range"],
    "images": [image],
    "services": services["services"],
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2)
PY
log "Wrote manifest.json"

# ---- Tarball ----------------------------------------------------------------
log "Creating ${OUT_TARBALL}..."
tar -czf "${OUT_TARBALL}" -C "${WORK_DIR}" images.tar manifest.json
log "Bundle produced: ${OUT_TARBALL} ($(du -h "${OUT_TARBALL}" | cut -f1))"
log "Done."
