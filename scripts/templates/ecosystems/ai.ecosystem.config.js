/**
 * PM2 ecosystem for the `ai` bundle container.
 * Container: {env_prefix}-ai   Ports: 3600-3799
 *
 * CPU PROTECTION (2026-04-25, fix/F2-cpu-protection):
 *   restart-throttle + node heap cap baked into mkApp() so every entry inherits.
 *   AI bundle keeps a slightly higher max_memory_restart (512M) because LLM
 *   adapters can briefly hold larger buffers.
 *   See core.ecosystem.config.js header for full rationale.
 */
const mkApp = (name, port) => ({
  name,
  script: 'dist/main.js',
  cwd: `/app/${name}`,
  instances: 1,
  exec_mode: 'fork',
  env: { NODE_ENV: 'production', PORT: port },
  max_memory_restart: '512M',
  min_uptime: '10s',
  max_restarts: 10,
  restart_delay: 4000,
  exp_backoff_restart_delay: 100,
  node_args: '--max-old-space-size=512',
});

module.exports = {
  apps: [
    mkApp('zorbit-ai-tele_uw', 3600),
  ],
};
