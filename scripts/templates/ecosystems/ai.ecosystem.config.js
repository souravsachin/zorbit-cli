/**
 * PM2 ecosystem for the `ai` bundle container.
 * Container: {env_prefix}-ai   Ports: 3600-3799
 */
const mkApp = (name, port) => ({
  name,
  script: 'dist/main.js',
  cwd: `/app/${name}`,
  instances: 1,
  exec_mode: 'fork',
  env: { NODE_ENV: 'production', NODE_OPTIONS: '--preserve-symlinks', PORT: port },
  max_memory_restart: '512M',
});

module.exports = {
  apps: [
    mkApp('zorbit-ai-tele_uw', 3600),
  ],
};
