#!/usr/bin/env bash
# zorbit-cli/scripts/bootstrap-lib/databases.sh
# Create shared Postgres, Mongo, Kafka, Redis via docker.
# Per-service databases are created via init SQL/JS executed after container is up.
# ---------------------------------------------------------------------------

_docker_available() {
  [[ "${DRY_RUN}" == "true" ]] && return 1
  docker info >/dev/null 2>&1
}

ensure_network() {
  local net_name="$1"
  if ! _docker_available; then
    run_cmd "Create docker network ${net_name}" docker network create "${net_name}"
    return 0
  fi
  if ! docker network inspect "${net_name}" >/dev/null 2>&1; then
    run_cmd "Create docker network ${net_name}" docker network create "${net_name}"
  else
    log_info "Docker network ${net_name} already exists"
  fi
}

start_postgres() {
  local env_name="$1"       # e.g. zorbit-dev
  local container="$2"      # e.g. ze-pg or zs-pg
  local port="$3"           # host port
  local data_root="$4"
  local password="${POSTGRES_PASSWORD:-zorbitdev123}"

  if _docker_available && docker ps -a --format '{{.Names}}' | grep -qx "${container}"; then
    log_info "Postgres container ${container} already exists — ensuring it is running"
    run_cmd "Start postgres ${container}" docker start "${container}" || true
    return 0
  fi

  run_cmd "Launch postgres ${container} on :${port}" docker run -d \
    --name "${container}" \
    --restart unless-stopped \
    -e POSTGRES_PASSWORD="${password}" \
    -e POSTGRES_USER=zorbit \
    -e POSTGRES_DB=postgres \
    -p "${port}:5432" \
    -v "${data_root}/postgres:/var/lib/postgresql/data" \
    postgres:16-alpine
}

start_mongo() {
  local container="$1"; local port="$2"; local data_root="$3"
  if _docker_available && docker ps -a --format '{{.Names}}' | grep -qx "${container}"; then
    run_cmd "Start mongo ${container}" docker start "${container}" || true
    return 0
  fi
  run_cmd "Launch mongo ${container} on :${port}" docker run -d \
    --name "${container}" \
    --restart unless-stopped \
    -p "${port}:27017" \
    -v "${data_root}/mongo:/data/db" \
    mongo:7
}

start_kafka() {
  local container="$1"; local port="$2"
  if _docker_available && docker ps -a --format '{{.Names}}' | grep -qx "${container}"; then
    run_cmd "Start kafka ${container}" docker start "${container}" || true
    return 0
  fi
  # 2026-04-27: switched bitnami/kafka:3.7 → apache/kafka:3.7.0 because Bitnami
  # stopped publishing free OSS images late 2025. Apache official uses KAFKA_*
  # (no _CFG_ prefix) per its env var contract — matches what zs-shared.yml
  # already uses for the compose-template path.
  run_cmd "Launch kafka ${container} on :${port}" docker run -d \
    --name "${container}" \
    --restart unless-stopped \
    -e KAFKA_NODE_ID=1 \
    -e KAFKA_PROCESS_ROLES=controller,broker \
    -e KAFKA_CONTROLLER_QUORUM_VOTERS="1@${container}:9093" \
    -e KAFKA_LISTENERS="PLAINTEXT://:9092,CONTROLLER://:9093" \
    -e KAFKA_ADVERTISED_LISTENERS="PLAINTEXT://${container}:9092" \
    -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
    -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP="CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT" \
    -e KAFKA_LOG_DIRS=/var/lib/kafka/data \
    -p "${port}:9092" \
    apache/kafka:3.7.0
}

start_redis() {
  local container="$1"; local port="$2"; local data_root="$3"
  if _docker_available && docker ps -a --format '{{.Names}}' | grep -qx "${container}"; then
    run_cmd "Start redis ${container}" docker start "${container}" || true
    return 0
  fi
  run_cmd "Launch redis ${container} on :${port}" docker run -d \
    --name "${container}" \
    --restart unless-stopped \
    -p "${port}:6379" \
    -v "${data_root}/redis:/data" \
    redis:7-alpine
}

wait_postgres_ready() {
  local container="$1"
  [[ "${DRY_RUN}" == "true" ]] && { log_info "DRY: would wait for ${container}"; return 0; }
  log_info "Waiting for postgres ${container} to be ready..."
  local i
  for i in $(seq 1 30); do
    if docker exec "${container}" pg_isready -U zorbit >/dev/null 2>&1; then
      log_ok "Postgres ${container} ready"
      return 0
    fi
    sleep 2
  done
  log_error "Postgres ${container} did not become ready in 60s"
  return 1
}

create_service_databases() {
  # Creates zorbit_<service> databases for every repo of type=service + db=postgres.
  # When ZORBIT_MODULE_LIST is set (cycle 106), only modules in the lockfile
  # have their database created.
  local container="$1"
  local manifest_file="$2"
  local module_list="${ZORBIT_MODULE_LIST:-}"
  local services
  services=$(python3 - "${manifest_file}" "${module_list}" <<'PY'
import sys, yaml, json
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
module_list_path = sys.argv[2] if len(sys.argv) > 2 else ""
allowed = None
if module_list_path:
    with open(module_list_path) as f:
        lockfile = json.load(f)
    allowed = set(lockfile.get('modules', []))
for r in data['repos']:
    if r.get('type') == 'service' and r.get('db') == 'postgres':
        if allowed is not None and r['name'] not in allowed:
            continue  # skipped per --module-list lockfile
        print(r['name'].replace('-', '_'))
PY
)
  local svc
  for svc in ${services}; do
    local db_name="zorbit_${svc#zorbit_}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "DRY: would create database ${db_name} in ${container}"
      continue
    fi
    docker exec "${container}" psql -U zorbit -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='${db_name}'" 2>/dev/null | grep -q 1 \
      && { log_info "DB ${db_name} already exists"; continue; }
    run_cmd "Create database ${db_name}" docker exec "${container}" \
      psql -U zorbit -d postgres -c "CREATE DATABASE \"${db_name}\";"
  done
}
