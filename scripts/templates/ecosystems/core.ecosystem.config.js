/**
 * PM2 ecosystem for the `core` bundle container.
 * Runs every core platform service on its assigned port (3000-3099).
 * Container: {env_prefix}-core
 *
 * Each app name follows `zorbit-<slug>` — used by the gates harness for
 * `docker exec {env_prefix}-core pm2 list` matching.
 *
 * CPU PROTECTION (2026-04-25, fix/F2-cpu-protection):
 *   - min_uptime: '10s'                — process must stay up 10s to be considered started
 *   - max_restarts: 10                 — after 10 failed restarts PM2 stops trying (errored)
 *   - restart_delay: 4000              — 4s base wait between restarts (was 0 -> tight loop)
 *   - exp_backoff_restart_delay: 100   — exponential backoff (100ms -> 200 -> 400 ...)
 *   - node_args: '--max-old-space-size=512'  — cap V8 heap at 512 MB per process
 * These five fields together prevent the runaway restart-loop CPU burn observed
 * in cycle 102 (counts 2200-7286 in <30 min, load avg 21 on a 4-vCPU VM).
 */
const baseLimits = {
  min_uptime: '10s',
  max_restarts: 10,
  restart_delay: 4000,
  exp_backoff_restart_delay: 100,
  node_args: '--max-old-space-size=512',
};

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
      ...baseLimits,
    },
    {
      name: 'zorbit-authorization',
      script: 'dist/main.js',
      cwd: '/app/zorbit-authorization',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3002 },
      max_memory_restart: '256M',
      ...baseLimits,
    },
    {
      name: 'zorbit-cor-deployment_registry',
      script: 'dist/main.js',
      cwd: '/app/zorbit-cor-deployment_registry',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3021 },
      max_memory_restart: '256M',
      ...baseLimits,
    },
    {
      name: 'zorbit-cor-module_registry',
      script: 'dist/main.js',
      cwd: '/app/zorbit-cor-module_registry',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3020 },
      max_memory_restart: '256M',
      ...baseLimits,
    },
    {
      name: 'zorbit-cor-observability',
      script: 'dist/main.js',
      cwd: '/app/zorbit-cor-observability',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3022 },
      max_memory_restart: '256M',
      ...baseLimits,
    },
    {
      name: 'zorbit-cor-secrets_vault',
      script: 'dist/main.js',
      cwd: '/app/zorbit-cor-secrets_vault',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3023 },
      max_memory_restart: '256M',
      ...baseLimits,
    },
    {
      name: 'zorbit-event_bus',
      script: 'dist/main.js',
      cwd: '/app/zorbit-event_bus',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3004 },
      max_memory_restart: '256M',
      ...baseLimits,
    },
    {
      name: 'zorbit-identity',
      script: 'dist/main.js',
      cwd: '/app/zorbit-identity',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3001 },
      max_memory_restart: '256M',
      ...baseLimits,
    },
    {
      name: 'zorbit-navigation',
      script: 'dist/main.js',
      cwd: '/app/zorbit-navigation',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3003 },
      max_memory_restart: '256M',
      ...baseLimits,
    },
    {
      name: 'zorbit-pii-vault',
      script: 'dist/main.js',
      cwd: '/app/zorbit-pii-vault',
      instances: 1,
      exec_mode: 'fork',
      env: { NODE_ENV: 'production', PORT: 3005 },
      max_memory_restart: '256M',
      ...baseLimits,
    },
  ],
};
