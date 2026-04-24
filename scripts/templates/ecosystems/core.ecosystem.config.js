/**
 * PM2 ecosystem for the `core` bundle container.
 * Runs every core platform service on its assigned port (3000-3099).
 * Container: {env_prefix}-core
 *
 * Each app name follows `zorbit-<slug>` — used by the gates harness for
 * `docker exec {env_prefix}-core pm2 list` matching.
 */
module.exports = {
  apps: [
    {
      name: 'zorbit-audit',
      script: 'dist/main.js',
      cwd: '/app/zorbit-audit',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3006 },
      max_memory_restart: '256M',
    },
    {
      name: 'zorbit-authorization',
      script: 'dist/main.js',
      cwd: '/app/zorbit-authorization',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3002 },
      max_memory_restart: '256M',
    },
    {
      name: 'zorbit-cor-deployment_registry',
      script: 'dist/main.js',
      cwd: '/app/zorbit-cor-deployment_registry',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3021 },
      max_memory_restart: '256M',
    },
    {
      name: 'zorbit-cor-module_registry',
      script: 'dist/main.js',
      cwd: '/app/zorbit-cor-module_registry',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3020 },
      max_memory_restart: '256M',
    },
    {
      name: 'zorbit-cor-observability',
      script: 'dist/main.js',
      cwd: '/app/zorbit-cor-observability',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3022 },
      max_memory_restart: '256M',
    },
    {
      name: 'zorbit-cor-secrets_vault',
      script: 'dist/main.js',
      cwd: '/app/zorbit-cor-secrets_vault',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3023 },
      max_memory_restart: '256M',
    },
    {
      name: 'zorbit-event_bus',
      script: 'dist/main.js',
      cwd: '/app/zorbit-event_bus',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3004 },
      max_memory_restart: '256M',
    },
    {
      name: 'zorbit-identity',
      script: 'dist/main.js',
      cwd: '/app/zorbit-identity',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3001 },
      max_memory_restart: '256M',
    },
    {
      name: 'zorbit-navigation',
      script: 'dist/main.js',
      cwd: '/app/zorbit-navigation',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3003 },
      max_memory_restart: '256M',
    },
    {
      name: 'zorbit-pii-vault',
      script: 'dist/main.js',
      cwd: '/app/zorbit-pii-vault',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3005 },
      max_memory_restart: '256M',
    },
  ],
};
