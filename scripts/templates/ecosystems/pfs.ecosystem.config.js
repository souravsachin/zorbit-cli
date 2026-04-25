/**
 * PM2 ecosystem for the `pfs` bundle container.
 * Container: {env_prefix}-pfs   Ports: 3100-3199
 */
const mkApp = (name, port) => ({
  name,
  script: 'dist/main.js',
  cwd: `/app/${name}`,
  instances: 1,
  exec_mode: 'fork',
  env: { NODE_ENV: 'production', NODE_OPTIONS: '--preserve-symlinks', PORT: port },
  max_memory_restart: '256M',
});

module.exports = {
  apps: [
    mkApp('zorbit-pfs-ai_gateway',            3100),
    mkApp('zorbit-pfs-analytics_reporting',   3101),
    mkApp('zorbit-pfs-api_integration',       3102),
    mkApp('zorbit-pfs-chat',                  3103),
    mkApp('zorbit-pfs-datatable',             3104),
    mkApp('zorbit-pfs-doc_generator',         3105),
    mkApp('zorbit-pfs-file_storage',          3106),
    mkApp('zorbit-pfs-file_viewer',           3107),
    mkApp('zorbit-pfs-form_builder',          3108),
    mkApp('zorbit-pfs-integration',           3109),
    mkApp('zorbit-pfs-interaction_recorder',  3110),
    mkApp('zorbit-pfs-kyc',                   3111),
    mkApp('zorbit-pfs-medical_coding',        3112),
    mkApp('zorbit-pfs-notification',          3113),
    mkApp('zorbit-pfs-payment_gateway',       3114),
    mkApp('zorbit-pfs-pixel',                 3115),
    mkApp('zorbit-pfs-realtime',              3116),
    mkApp('zorbit-pfs-rpa_integration',       3117),
    mkApp('zorbit-pfs-rtc',                   3118),
    mkApp('zorbit-pfs-rules_engine',          3119),
    mkApp('zorbit-pfs-secrets',               3120),
    mkApp('zorbit-pfs-seeder',                3121),
    mkApp('zorbit-pfs-verification',          3122),
    mkApp('zorbit-pfs-voice',                 3123),
    mkApp('zorbit-pfs-voice_engine',          3124),
    mkApp('zorbit-pfs-white_label',           3125),
    mkApp('zorbit-pfs-workflow_engine',       3127),
    mkApp('zorbit-pfs-zmb_factory',           3128),
  ],
};
