#!/usr/bin/env bash
# =============================================================================
# Generates per-bundle .env files for a specific environment.
# =============================================================================
# Runs on the VM (or locally before rsync) to produce:
#   /etc/zorbit/<env>/env/core.env
#   /etc/zorbit/<env>/env/pfs.env
#   /etc/zorbit/<env>/env/apps.env
#   /etc/zorbit/<env>/env/ai.env
#   /etc/zorbit/<env>/env/web.env
#
# Each .env is consumed by `env_file:` in the corresponding docker-compose
# service block.
#
# Usage:
#   bash ze-env-template.sh dev /etc/zorbit/ze
# =============================================================================
set -euo pipefail

ENV_NAME="${1:-dev}"           # dev | qa | demo | uat
ENV_PREFIX="${2:-ze}"          # ze | zq | zd | zu
TARGET_DIR="${3:-/etc/zorbit/${ENV_PREFIX}}"

mkdir -p "${TARGET_DIR}/env"

# ---- shared across all bundles in this env -------------------------------
SHARED_ENV=$(cat <<EOF
NODE_ENV=${ENV_NAME}
ZORBIT_ENV_PREFIX=${ENV_PREFIX}
ZORBIT_ENV_NAME=${ENV_NAME}

# Databases — zs-pg on shared network, DB name = <prefix>_<slug>
DATABASE_HOST=zs-pg
DATABASE_PORT=5432
DATABASE_USER=zorbit
DATABASE_USERNAME=zorbit
DATABASE_PASSWORD=${ZS_PG_PASSWORD:-zorbit_nonprod_secret}
DATABASE_SYNCHRONIZE=true
DATABASE_LOGGING=false

# Mongo for datatable/form_builder/white_label/zmb_factory/verification
MONGO_URI=mongodb://zorbit:${ZS_MONGO_PASSWORD:-zorbit_nonprod_secret}@zs-mongo:27017/${ENV_PREFIX}_platform?authSource=admin&directConnection=true

# Kafka
KAFKA_BROKERS=zs-kafka:9092

# Redis
REDIS_URL=redis://zs-redis:6379/0

# JWT (shared across env's services — not across envs)
JWT_SECRET=${ZORBIT_JWT_SECRET:-zorbit-${ENV_NAME}-jwt-secret-2026}
JWT_EXPIRATION=3600

# PII-vault encryption
ENCRYPTION_MASTER_KEY=${ZORBIT_ENC_KEY:-$(openssl rand -hex 32)}

# Platform module secret
PLATFORM_MODULE_SECRET=${ZORBIT_MODULE_SECRET:-zorbit-${ENV_NAME}-module-secret-2026}

# CORS + frontend
CORS_ORIGINS=https://zorbit-${ENV_NAME}.onezippy.ai,http://localhost:3000
FRONTEND_URL=https://zorbit-${ENV_NAME}.onezippy.ai

# Inter-service URLs (via docker DNS on zs-shared-net)
IDENTITY_SERVICE_URL=http://${ENV_PREFIX}-core:3001
AUTHORIZATION_SERVICE_URL=http://${ENV_PREFIX}-core:3002
NAVIGATION_SERVICE_URL=http://${ENV_PREFIX}-core:3003
EVENT_BUS_URL=http://${ENV_PREFIX}-core:3004
PII_VAULT_URL=http://${ENV_PREFIX}-core:3005
AUDIT_SERVICE_URL=http://${ENV_PREFIX}-core:3006
MODULE_REGISTRY_URL=http://${ENV_PREFIX}-core:3020
DEPLOYMENT_REGISTRY_URL=http://${ENV_PREFIX}-core:3021
EOF
)

write_env() {
  local bundle="$1"
  local extra="$2"
  local out="${TARGET_DIR}/env/${bundle}.env"
  {
    echo "# Auto-generated: $(date -Iseconds)"
    echo "$SHARED_ENV"
    [[ -n "$extra" ]] && echo "$extra"
  } > "$out"
  chmod 600 "$out"
  echo "wrote $out"
}

write_env core ""
write_env pfs ""
write_env apps ""
write_env ai ""
write_env web "NGINX_WORKER_CONNECTIONS=1024"

echo "==> env files for ${ENV_NAME} (${ENV_PREFIX}) at ${TARGET_DIR}/env/"
