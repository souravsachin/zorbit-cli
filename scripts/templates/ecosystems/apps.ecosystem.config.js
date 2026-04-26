/**
 * PM2 ecosystem for the `apps` bundle container.
 * Container: {env_prefix}-apps   Ports: 3200-3599
 *
 * CPU PROTECTION (2026-04-25, fix/F2-cpu-protection):
 *   restart-throttle + node heap cap baked into mkApp() so every entry inherits.
 *   See core.ecosystem.config.js header for full rationale.
 *
 * MONGO ENV (2026-04-26, soldier (n) fix/n-pcg5-mongodb-uri):
 *   Apps that use Mongoose (e.g. zorbit-app-pcg5) read both MONGO_URI and
 *   MONGODB_URI as fallbacks. Setting both eliminates source/dist drift
 *   issues where source uses MONGO_URI but compiled dist still references
 *   MONGODB_URI. zs-mongo is the shared Mongo container in the dev/qa/demo/
 *   prod env-stack. ze_platform is the shared logical DB.
 *
 * VITE SPA RECLASS (2026-04-26, soldier (p) fix/cycle-105-vite-spa-reclass-ecosystem):
 *   Removed 4 Vite/React SPAs that were misclassified as Node services and
 *   crash-looping with "Script not found: dist/main.js" (Vite emits dist/index.html
 *   + assets/, not dist/main.js):
 *     - zorbit-app-claims_intake   (was 3203)
 *     - zorbit-app-prospect_portal (was 3221)
 *     - zorbit-portal-customer     (was 3229)
 *     - zorbit-portal-prospect     (was 3230)
 *   These are now served as static SPAs by ze-web nginx from
 *   /var/www/spa-apps/<svc>/dist/. See ze-web-nginx.conf SPA static apps block.
 */
const MONGO_URI = process.env.MONGO_URI ||
  'mongodb://zorbit:zorbit_nonprod_secret@zs-mongo:27017/ze_platform?authSource=admin';

const mkApp = (name, port) => ({
  name,
  script: 'dist/main.js',
  cwd: `/app/${name}`,
  instances: 1,
  exec_mode: 'fork',
  env: {
    NODE_ENV: 'production',
    PORT: port,
    NODE_OPTIONS: '--preserve-symlinks',
    // Both var names — covers source/dist drift across pcg5 + future Mongoose apps
    MONGO_URI,
    MONGODB_URI: MONGO_URI,
  },
  max_memory_restart: '256M',
  min_uptime: '10s',
  max_restarts: 10,
  restart_delay: 4000,
  exp_backoff_restart_delay: 100,
  node_args: '--max-old-space-size=512',
});

module.exports = {
  apps: [
    mkApp('sample-customer-service',                    3200),
    mkApp('zorbit-app-broker',                          3201),
    mkApp('zorbit-app-claims_core',                     3202),
    // 3203 zorbit-app-claims_intake — RECLASSIFIED to Vite SPA (served by ze-web)
    mkApp('zorbit-app-hi_claim_adjudication_workflow',  3204),
    mkApp('zorbit-app-hi_claim_decisioning',            3205),
    mkApp('zorbit-app-hi_claim_initiation',             3206),
    mkApp('zorbit-app-hi_claim_payment_recon',          3207),
    mkApp('zorbit-app-hi_customer_portal',              3208),
    mkApp('zorbit-app-hi_quotation',                    3209),
    mkApp('zorbit-app-hi_retail_quotation',             3210),
    mkApp('zorbit-app-hi_sme_quotation',                3211),
    mkApp('zorbit-app-hi_uw_decisioning',               3212),
    mkApp('zorbit-app-jayna',                           3213),
    mkApp('zorbit-app-manufacturing_demo',              3214),
    mkApp('zorbit-app-mi_quotation',                    3215),
    mkApp('zorbit-app-network_empanelment_application', 3216),
    mkApp('zorbit-app-network_empanelment_workflow',    3217),
    mkApp('zorbit-app-pcg4',                            3218),
    mkApp('zorbit-app-pcg5',                            3219),
    mkApp('zorbit-app-product_pricing',                 3220),
    // 3221 zorbit-app-prospect_portal — RECLASSIFIED to Vite SPA (served by ze-web)
    mkApp('zorbit-app-retail_banking_demo',             3222),
    mkApp('zorbit-app-sample',                          3223),
    mkApp('zorbit-app-sample_module',                   3224),
    mkApp('zorbit-app-slice_of_pie',                    3225),
    mkApp('zorbit-app-uw_workflow',                     3226),
    mkApp('zorbit-app-wealth_mgmt_demo',                3227),
    mkApp('zorbit-app-zmb_selftest',                    3228),
    // 3229 zorbit-portal-customer — RECLASSIFIED to Vite SPA (served by ze-web)
    // 3230 zorbit-portal-prospect — RECLASSIFIED to Vite SPA (served by ze-web)
  ],
};
