/**
 * zorbit env install — OS-installer-style preset+override selector.
 *
 * Owner directive MSG-093 2026-04-27. Cycle 106. Pattern: Debian tasksel +
 * Red Hat Anaconda. Driven by zorbit-core/platform-spec/install-presets.json.
 *
 * Resolution layers (in order):
 *   1. Read install-presets.json
 *   2. Resolve --preset to base module list
 *   3. Always-required groups merged in
 *   4. --add merged in
 *   5. --remove subtracted out
 *   6. Validate every resolved module exists in all-repos.yaml
 *   7. Print preview + memory/disk estimate
 *   8. Confirmation gate (skipped with --yes)
 *   9. Write lockfile to /etc/zorbit/<env>-install.lock (or --lockfile-path)
 *  10. Hand off to bootstrap-env.sh --module-list <lockfile> (or --dry-run)
 *
 * Usage:
 *   zorbit env install --env=qa --preset=recommended
 *   zorbit env install --env=qa --preset=recommended --add=zorbit-app-jayna
 *   zorbit env install --env=qa --preset=max --remove=zorbit-pfs-voice_engine
 *   zorbit env install --env=qa --preset=minimal --interactive
 *   zorbit env install --env=qa --preset=max --dry-run
 */

import { Command } from 'commander';
import * as fs from 'fs-extra';
import * as path from 'path';
import * as os from 'os';
import { spawnSync } from 'child_process';
import chalk from 'chalk';

// ---------------------------------------------------------------------------
// Types — shape of install-presets.json
// ---------------------------------------------------------------------------

interface PresetGroup {
  label: string;
  description: string;
  modules?: string[];
  planned_modules?: string[];
  always_required?: boolean;
}

interface Preset {
  label: string;
  description: string;
  estimated_services?: number;
  estimated_memory_gb?: number;
  estimated_disk_gb?: number;
  includes_groups?: string[];
  includes_modules?: string[];
  includes_all_groups?: boolean;
}

interface InstallPresetsSpec {
  version: string;
  spec_owner: string;
  updated: string;
  groups: Record<string, PresetGroup>;
  presets: Record<string, Preset>;
}

interface ResolvedInstall {
  env: string;
  preset: string;
  modules: string[];
  added: string[];
  removed: string[];
  skipped_planned: string[];
  estimated_services: number;
  estimated_memory_gb: number;
  estimated_disk_gb: number;
  source_spec_version: string;
  resolved_at: string;
  resolver_version: string;
}

// ---------------------------------------------------------------------------
// Path discovery — works whether running from source dist or installed CLI.
// ---------------------------------------------------------------------------

const RESOLVER_VERSION = '1.0.0';

function findRepoRoot(): string {
  // env override first
  if (process.env.ZORBIT_REPO_ROOT) return process.env.ZORBIT_REPO_ROOT;
  // walk up from cwd looking for 02_repos/zorbit-core
  let dir = process.cwd();
  for (let i = 0; i < 8; i++) {
    if (fs.existsSync(path.join(dir, '02_repos', 'zorbit-core'))) {
      return path.join(dir, '02_repos');
    }
    if (fs.existsSync(path.join(dir, 'zorbit-core', 'platform-spec'))) {
      return dir;
    }
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  // common layouts
  const candidates = [
    '/Users/s/workspace/zorbit/02_repos',
    path.join(os.homedir(), 'workspace', 'zorbit', '02_repos'),
    '/work/zorbit/02_repos',
  ];
  for (const c of candidates) {
    if (fs.existsSync(path.join(c, 'zorbit-core'))) return c;
  }
  throw new Error(
    'Could not find zorbit-core. Set ZORBIT_REPO_ROOT to the directory containing zorbit-core/.',
  );
}

function loadPresetsSpec(repoRoot: string): InstallPresetsSpec {
  const specPath = path.join(repoRoot, 'zorbit-core', 'platform-spec', 'install-presets.json');
  if (!fs.existsSync(specPath)) {
    throw new Error(`install-presets.json not found at ${specPath}`);
  }
  return JSON.parse(fs.readFileSync(specPath, 'utf-8')) as InstallPresetsSpec;
}

function loadManifestModuleNames(repoRoot: string): Set<string> {
  const manifestPath = path.join(repoRoot, 'zorbit-core', 'platform-spec', 'all-repos.yaml');
  if (!fs.existsSync(manifestPath)) {
    throw new Error(`all-repos.yaml not found at ${manifestPath}`);
  }
  const content = fs.readFileSync(manifestPath, 'utf-8');
  const names = new Set<string>();
  const re = /^\s*-\s*name:\s*(\S+)/gm;
  let m: RegExpExecArray | null;
  while ((m = re.exec(content)) !== null) {
    names.add(m[1]);
  }
  return names;
}

// ---------------------------------------------------------------------------
// Slug normalisation — accept short or canonical forms.
//   "rtc"         -> "zorbit-pfs-rtc" (if pfs-rtc is the canonical)
//   "pfs-rtc"     -> "zorbit-pfs-rtc"
//   "hi_uw_decisioning" -> "zorbit-app-hi_uw_decisioning"
// ---------------------------------------------------------------------------

function normaliseSlug(slug: string, manifestNames: Set<string>): string | null {
  const candidates = [
    slug,
    `zorbit-${slug}`,
    `zorbit-pfs-${slug}`,
    `zorbit-app-${slug}`,
    `zorbit-cor-${slug}`,
  ];
  for (const c of candidates) {
    if (manifestNames.has(c)) return c;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Resolver — applies preset + add/remove + planned-module filtering.
// ---------------------------------------------------------------------------

function resolveInstallPlan(opts: {
  env: string;
  preset: string;
  add: string[];
  remove: string[];
  spec: InstallPresetsSpec;
  manifestNames: Set<string>;
}): ResolvedInstall {
  const { env, preset, spec, manifestNames } = opts;
  if (!spec.presets[preset]) {
    throw new Error(
      `Unknown preset "${preset}". Available: ${Object.keys(spec.presets).join(', ')}`,
    );
  }
  const p = spec.presets[preset];

  const resolved = new Set<string>();
  const skippedPlanned: string[] = [];

  // 1. always_required groups (merged regardless of preset choice)
  for (const [gkey, g] of Object.entries(spec.groups)) {
    if (g.always_required) {
      (g.modules || []).forEach((m) => resolved.add(m));
    }
  }

  // 2. groups from preset (or all groups if includes_all_groups)
  let groupsToInclude: string[];
  if (p.includes_all_groups) {
    groupsToInclude = Object.keys(spec.groups);
  } else {
    groupsToInclude = p.includes_groups || [];
  }
  for (const gkey of groupsToInclude) {
    const g = spec.groups[gkey];
    if (!g) {
      console.warn(chalk.yellow(`  WARN: preset "${preset}" references unknown group "${gkey}"`));
      continue;
    }
    (g.modules || []).forEach((m) => resolved.add(m));
    (g.planned_modules || []).forEach((m) => skippedPlanned.push(m));
  }

  // 3. preset-level extra modules
  for (const m of p.includes_modules || []) {
    resolved.add(m);
  }

  // 4. --add overrides (normalise short slugs)
  const added: string[] = [];
  for (const raw of opts.add) {
    const canonical = normaliseSlug(raw, manifestNames);
    if (!canonical) {
      throw new Error(
        `--add: "${raw}" does not resolve to any module in all-repos.yaml (tried: ${raw}, zorbit-${raw}, zorbit-pfs-${raw}, zorbit-app-${raw}, zorbit-cor-${raw})`,
      );
    }
    resolved.add(canonical);
    added.push(canonical);
  }

  // 5. --remove subtractions (normalise short slugs)
  const removed: string[] = [];
  for (const raw of opts.remove) {
    const canonical = normaliseSlug(raw, manifestNames);
    if (!canonical) {
      console.warn(
        chalk.yellow(`  WARN: --remove: "${raw}" does not resolve — ignoring`),
      );
      continue;
    }
    if (resolved.delete(canonical)) {
      removed.push(canonical);
    } else {
      console.warn(
        chalk.yellow(`  WARN: --remove: "${canonical}" was not in the resolved set — no-op`),
      );
    }
  }

  // 6. validate every resolved module exists in manifest
  const missing: string[] = [];
  for (const m of resolved) {
    if (!manifestNames.has(m)) missing.push(m);
  }
  if (missing.length > 0) {
    throw new Error(
      `Resolver produced modules absent from all-repos.yaml: ${missing.join(', ')}. Fix install-presets.json or publish the missing repos.`,
    );
  }

  const sortedModules = Array.from(resolved).sort();

  return {
    env,
    preset,
    modules: sortedModules,
    added,
    removed,
    skipped_planned: Array.from(new Set(skippedPlanned)),
    estimated_services: p.estimated_services ?? sortedModules.length,
    estimated_memory_gb: p.estimated_memory_gb ?? 0,
    estimated_disk_gb: p.estimated_disk_gb ?? 0,
    source_spec_version: spec.version,
    resolved_at: new Date().toISOString(),
    resolver_version: RESOLVER_VERSION,
  };
}

// ---------------------------------------------------------------------------
// Preview — print resolved plan in human-friendly form.
// ---------------------------------------------------------------------------

function printPreview(plan: ResolvedInstall, spec: InstallPresetsSpec): void {
  const p = spec.presets[plan.preset];
  console.log();
  console.log(chalk.bold.cyan('═══ Zorbit env install — resolved plan ═══'));
  console.log();
  console.log(chalk.bold('  env:           ') + plan.env);
  console.log(chalk.bold('  preset:        ') + chalk.yellow(plan.preset) + chalk.gray(`  (${p.label})`));
  console.log(chalk.bold('  spec version:  ') + plan.source_spec_version);
  console.log(chalk.bold('  resolver:      ') + plan.resolver_version);
  console.log();
  console.log(chalk.bold('  estimates:'));
  console.log(`    services:    ${chalk.green(String(plan.modules.length))}  (preset baseline ${plan.estimated_services})`);
  console.log(`    memory:      ${chalk.green(String(plan.estimated_memory_gb))} GB`);
  console.log(`    disk:        ${chalk.green(String(plan.estimated_disk_gb))} GB`);
  console.log();

  if (plan.added.length > 0) {
    console.log(chalk.bold('  --add:         ') + plan.added.map((m) => chalk.green('+' + m)).join(' '));
  }
  if (plan.removed.length > 0) {
    console.log(chalk.bold('  --remove:      ') + plan.removed.map((m) => chalk.red('-' + m)).join(' '));
  }
  if (plan.skipped_planned.length > 0) {
    console.log(chalk.bold('  planned (skip):') + ' ' + chalk.gray(plan.skipped_planned.join(', ')));
  }

  console.log();
  console.log(chalk.bold(`  modules to install (${plan.modules.length}):`));
  for (const m of plan.modules) {
    console.log('    ' + chalk.cyan('•') + ' ' + m);
  }
  console.log();
}

// ---------------------------------------------------------------------------
// Lockfile writer — audit trail of what was installed for this env.
// ---------------------------------------------------------------------------

function writeLockfile(plan: ResolvedInstall, lockfilePath: string): void {
  fs.ensureDirSync(path.dirname(lockfilePath));
  fs.writeFileSync(lockfilePath, JSON.stringify(plan, null, 2) + '\n', 'utf-8');
}

function defaultLockfilePath(env: string): string {
  // /etc/zorbit/<env>-install.lock if writable, else $HOME/.zorbit/<env>-install.lock
  const sysPath = `/etc/zorbit/${env}-install.lock`;
  try {
    fs.ensureDirSync('/etc/zorbit');
    fs.accessSync('/etc/zorbit', fs.constants.W_OK);
    return sysPath;
  } catch {
    return path.join(os.homedir(), '.zorbit', `${env}-install.lock`);
  }
}

// ---------------------------------------------------------------------------
// Confirmation prompt — minimal stdin reader (no inquirer dep needed here).
// ---------------------------------------------------------------------------

async function confirmYesNo(question: string): Promise<boolean> {
  process.stdout.write(question + ' ');
  return new Promise((resolve) => {
    const onData = (chunk: Buffer) => {
      const ans = chunk.toString().trim().toLowerCase();
      process.stdin.removeListener('data', onData);
      process.stdin.pause();
      resolve(ans === 'y' || ans === 'yes');
    };
    process.stdin.resume();
    process.stdin.once('data', onData);
  });
}

// ---------------------------------------------------------------------------
// Interactive TUI — uses whiptail if available, else falls back to readline.
// ---------------------------------------------------------------------------

function whiptailAvailable(): boolean {
  const r = spawnSync('which', ['whiptail']);
  return r.status === 0;
}

function runInteractiveTui(spec: InstallPresetsSpec): {
  preset: string;
  add: string[];
  remove: string[];
} {
  if (!whiptailAvailable()) {
    console.log(chalk.yellow('whiptail not found — falling back to text menu.'));
    return runTextMenu(spec);
  }

  // Step 1: preset radio list
  const presetItems: string[] = [];
  for (const [k, p] of Object.entries(spec.presets)) {
    presetItems.push(k, p.label, k === 'recommended' ? 'ON' : 'OFF');
  }

  const presetRes = spawnSync(
    'whiptail',
    [
      '--title',
      'Zorbit env install — choose preset',
      '--radiolist',
      'Pick a base preset (TAB to select, SPACE to toggle, ENTER to confirm):',
      '20',
      '78',
      '8',
      ...presetItems,
    ],
    { stdio: ['inherit', 'inherit', 'pipe'] },
  );
  if (presetRes.status !== 0) {
    throw new Error('Cancelled at preset selection');
  }
  const preset = (presetRes.stderr.toString() || 'recommended').trim();

  // Step 2: optional add modules — checkbox of all manifest modules NOT in preset
  // For simplicity in v1, skip the per-module checkbox (printed reminder).
  console.log(chalk.gray('(per-module add/remove from TUI is v2 — use --add / --remove flags for now)'));

  return { preset, add: [], remove: [] };
}

function runTextMenu(spec: InstallPresetsSpec): {
  preset: string;
  add: string[];
  remove: string[];
} {
  console.log(chalk.bold('\nAvailable presets:\n'));
  const keys = Object.keys(spec.presets);
  keys.forEach((k, i) => {
    const p = spec.presets[k];
    console.log(`  ${chalk.cyan(`[${i + 1}]`)} ${chalk.bold(k.padEnd(14))} ${p.label}`);
    console.log(`        ${chalk.gray(p.description)}`);
  });
  console.log();
  // Default to recommended
  const idx = keys.indexOf('recommended');
  return { preset: keys[idx >= 0 ? idx : 0], add: [], remove: [] };
}

// ---------------------------------------------------------------------------
// Main — wire commander.
// ---------------------------------------------------------------------------

export function envInstallCommand(program: Command): void {
  const env = program.command('env').description('Environment lifecycle commands');

  env
    .command('install')
    .description('Resolve + install a Zorbit env from a preset (with optional --add/--remove overrides).')
    .requiredOption('--env <name>', 'Target env (dev|qa|demo|uat|prod)')
    .option('--preset <name>', 'Base preset (minimal|recommended|max|developer)', 'recommended')
    .option('--add <slugs>', 'Comma-separated module slugs to add', '')
    .option('--remove <slugs>', 'Comma-separated module slugs to remove', '')
    .option('--interactive', 'Use whiptail TUI to choose preset + overrides', false)
    .option('--demo', 'Run TUI but do not actually install (preview only)', false)
    .option('--yes', 'Skip confirmation prompt', false)
    .option('--dry-run', 'Print plan + lockfile but do not invoke bootstrap-env.sh', false)
    .option('--lockfile-path <path>', 'Override default lockfile path')
    .option('--bootstrap-script <path>', 'Path to bootstrap-env.sh', '')
    .action(async (opts: {
      env: string;
      preset: string;
      add: string;
      remove: string;
      interactive: boolean;
      demo: boolean;
      yes: boolean;
      dryRun: boolean;
      lockfilePath?: string;
      bootstrapScript?: string;
    }) => {
      try {
        const repoRoot = findRepoRoot();
        const spec = loadPresetsSpec(repoRoot);
        const manifestNames = loadManifestModuleNames(repoRoot);

        let preset = opts.preset;
        let addList = opts.add ? opts.add.split(',').map((s) => s.trim()).filter(Boolean) : [];
        let removeList = opts.remove ? opts.remove.split(',').map((s) => s.trim()).filter(Boolean) : [];

        if (opts.interactive || opts.demo) {
          const sel = runInteractiveTui(spec);
          preset = sel.preset;
          addList = [...addList, ...sel.add];
          removeList = [...removeList, ...sel.remove];
        }

        const plan = resolveInstallPlan({
          env: opts.env,
          preset,
          add: addList,
          remove: removeList,
          spec,
          manifestNames,
        });

        printPreview(plan, spec);

        if (opts.demo) {
          console.log(chalk.yellow('--demo: not writing lockfile, not invoking bootstrap.'));
          return;
        }

        if (!opts.yes && !opts.dryRun) {
          const ok = await confirmYesNo(chalk.bold('Proceed and write lockfile? [y/N]'));
          if (!ok) {
            console.log(chalk.yellow('Cancelled by user.'));
            process.exit(2);
          }
        }

        const lockfilePath = opts.lockfilePath || defaultLockfilePath(opts.env);
        writeLockfile(plan, lockfilePath);
        console.log(chalk.green(`  WROTE`) + ' ' + lockfilePath);

        if (opts.dryRun) {
          console.log(chalk.yellow('\n--dry-run: not invoking bootstrap-env.sh.'));
          console.log(chalk.gray(`Hand-off command would be:`));
          const bs = opts.bootstrapScript || path.join(repoRoot, 'zorbit-cli', 'scripts', 'bootstrap-env.sh');
          console.log(chalk.gray(`  ${bs} --env ${opts.env} --module-list ${lockfilePath}`));
          return;
        }

        const bootstrapScript = opts.bootstrapScript || path.join(repoRoot, 'zorbit-cli', 'scripts', 'bootstrap-env.sh');
        if (!fs.existsSync(bootstrapScript)) {
          console.log(chalk.yellow(`bootstrap-env.sh not found at ${bootstrapScript}; skipping invocation. Lockfile is at ${lockfilePath}.`));
          return;
        }
        console.log(chalk.cyan(`\nHanding off to ${bootstrapScript}...`));
        const r = spawnSync(bootstrapScript, ['--env', opts.env, '--module-list', lockfilePath], {
          stdio: 'inherit',
        });
        process.exit(r.status ?? 0);
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error(chalk.red('env install failed: ') + msg);
        process.exit(1);
      }
    });
}

// Test exports for unit testing.
export const __test__ = {
  resolveInstallPlan,
  normaliseSlug,
  loadPresetsSpec,
  loadManifestModuleNames,
  findRepoRoot,
};
