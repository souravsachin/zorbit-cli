#!/usr/bin/env -S npx ts-node
// @ts-nocheck
/**
 * section-s-structure.ts — Section S: Module Structure Validation
 *
 * Per test-plan-v3 Section S (owner directive 2026-04-27, MSG-101 #7 + MSG-105):
 *   For each module declared in
 *   `02_repos/zorbit-core/platform-spec/module-expected-structure.json`,
 *   walk the live menu tree and assert every required group + item
 *   resolves to a feRoute. Missing required = exit non-zero.
 *
 * Pre-req:
 *   B.00 must have passed in this run (need authenticated super-admin
 *   session). This validator authenticates fresh against the public URL
 *   using creds at ~/.claude/secrets/zorbit-superadmin.env.
 *
 * Usage:
 *   ZORBIT_ENV=dev npx ts-node section-s-structure.ts
 *   ZORBIT_ENV=qa  npx ts-node section-s-structure.ts
 *
 * Reads:
 *   - $ZORBIT_ENV (default: dev)
 *   - super-admin EMAIL/PASSWORD from ~/.claude/secrets/zorbit-superadmin.env
 *   - spec from <repo-root>/02_repos/zorbit-core/platform-spec/module-expected-structure.json
 *
 * Writes:
 *   - 00_docs/platform/cycle-runs/cycle-${CYCLE}/section-s-report.json
 *   - stdout: human-readable summary table
 *
 * Exits non-zero if ANY module has non-empty missing_required.
 */

import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import * as https from 'https';
import * as http from 'http';
import { URL } from 'url';

const ENV = process.env.ZORBIT_ENV || 'dev';
const HOST = process.env.ZORBIT_HOST || `https://zorbit-${ENV}.onezippy.ai`;
const CYCLE = process.env.ZORBIT_CYCLE || '106';
const SECRETS_PATH =
  process.env.ZORBIT_SECRETS ||
  path.join(os.homedir(), '.claude', 'secrets', 'zorbit-superadmin.env');
// Repo-root resolution: respect $ZORBIT_REPO_ROOT first, then walk up looking
// for `02_repos/zorbit-core/platform-spec/`. Falls back to ../../../.. relative
// to this script, which is correct when the script lives inside a normal
// zorbit-cli checkout under 02_repos/.
function findRepoRoot(start: string): string {
  if (process.env.ZORBIT_REPO_ROOT) return process.env.ZORBIT_REPO_ROOT;
  let dir = start;
  for (let i = 0; i < 8; i++) {
    if (
      fs.existsSync(
        path.join(dir, '02_repos', 'zorbit-core', 'platform-spec', 'module-expected-structure.json'),
      )
    ) {
      return dir;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return path.resolve(start, '../../../..');
}
const REPO_ROOT = findRepoRoot(__dirname);
const SPEC_PATH = path.join(
  REPO_ROOT,
  '02_repos/zorbit-core/platform-spec/module-expected-structure.json',
);
const OUT_DIR = path.join(
  REPO_ROOT,
  `00_docs/platform/cycle-runs/cycle-${CYCLE}`,
);
const TIMESTAMP = new Date().toISOString();

// ---------- types ----------

interface ModuleSpec {
  scaffold?: string;
  businessLine?: string;
  capabilityArea?: string;
  menuId: string;
  feRoute: string;
  required_groups: string[];
  optional_groups?: string[];
  required_guide_items?: string[];
  required_data_items?: string[];
  required_setup_items?: string[];
  required_deployment_items?: string[];
  required_operations_items?: string[];
  required_demo_items?: string[];
  required_config_items?: string[];
  required_help_items?: string[];
  optional_guide_items?: string[];
  optional_data_items?: string[];
  optional_setup_items?: string[];
  optional_deployment_items?: string[];
  optional_operations_items?: string[];
  optional_demo_items?: string[];
  optional_config_items?: string[];
  optional_help_items?: string[];
  [k: string]: unknown;
}

interface Spec {
  version: string;
  groupKeys: { values: string[]; synonyms: Record<string, string> };
  guideRequiredTabs: { values: string[] };
  modules: Record<string, ModuleSpec | unknown>;
}

interface MenuNode {
  id?: string;
  label?: string;
  slug?: string;
  route?: string;
  feRoute?: string;
  level?: number;
  children?: MenuNode[];
  [k: string]: unknown;
}

interface ModuleResult {
  module: string;
  menuId: string;
  feRoute: string;
  expected: {
    required_groups: string[];
    required_items: Record<string, string[]>;
    optional_groups: string[];
    optional_items: Record<string, string[]>;
  };
  actual: {
    found_in_menu: boolean;
    groups: string[];
    items: Record<string, string[]>;
  };
  missing_required: string[];
  missing_optional: string[];
  pass: boolean;
}

// ---------- utils ----------

function readSecrets(): { email: string; password: string; userHashId?: string } {
  if (!fs.existsSync(SECRETS_PATH)) {
    throw new Error(`secrets file missing: ${SECRETS_PATH}`);
  }
  const text = fs.readFileSync(SECRETS_PATH, 'utf-8');
  const m: Record<string, string> = {};
  for (const line of text.split('\n')) {
    const mm = line.match(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/);
    if (mm) m[mm[1]] = mm[2].replace(/^['"]|['"]$/g, '');
  }
  // Support both naming conventions:
  //   EMAIL / PASSWORD
  //   ZORBIT_SUPERADMIN_EMAIL / ZORBIT_SUPERADMIN_PASSWORD / ZORBIT_SUPERADMIN_USER_HASH
  const email = m.EMAIL || m.ZORBIT_SUPERADMIN_EMAIL || '';
  const password = m.PASSWORD || m.ZORBIT_SUPERADMIN_PASSWORD || '';
  const userHashId = m.ZORBIT_SUPERADMIN_USER_HASH || m.USER_HASH || '';
  if (!password) {
    throw new Error(
      `secrets file missing PASSWORD/ZORBIT_SUPERADMIN_PASSWORD: ${SECRETS_PATH}`,
    );
  }
  if (!email && !userHashId) {
    throw new Error(
      `secrets file needs EMAIL or ZORBIT_SUPERADMIN_USER_HASH: ${SECRETS_PATH}`,
    );
  }
  return { email, password, userHashId };
}

function httpRequest(
  url: string,
  opts: { method?: string; headers?: Record<string, string>; body?: string } = {},
): Promise<{ status: number; headers: Record<string, string>; body: string }> {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const lib = u.protocol === 'https:' ? https : http;
    const req = lib.request(
      {
        method: opts.method || 'GET',
        hostname: u.hostname,
        port: u.port || (u.protocol === 'https:' ? 443 : 80),
        path: u.pathname + u.search,
        headers: opts.headers || {},
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () =>
          resolve({
            status: res.statusCode || 0,
            headers: res.headers as Record<string, string>,
            body: Buffer.concat(chunks).toString('utf-8'),
          }),
        );
      },
    );
    req.on('error', reject);
    if (opts.body) req.write(opts.body);
    req.end();
  });
}

async function login(email: string, password: string): Promise<{ token: string; userHashId: string }> {
  const url = `${HOST}/api/identity/api/v1/G/auth/login`;
  const res = await httpRequest(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (res.status !== 200 && res.status !== 201) {
    throw new Error(`login failed: ${res.status} ${res.body.slice(0, 200)}`);
  }
  const j = JSON.parse(res.body);
  const token = j.accessToken || j.access_token || j.token;
  if (!token) throw new Error(`login response missing token: ${res.body.slice(0, 200)}`);
  // decode JWT to get userHashId
  const parts = token.split('.');
  const payload = JSON.parse(Buffer.from(parts[1], 'base64').toString('utf-8'));
  const userHashId = payload.sub || payload.userHashId || payload.user_id;
  if (!userHashId) throw new Error(`token missing sub: ${JSON.stringify(payload)}`);
  return { token, userHashId };
}

async function fetchMenu(token: string, userHashId: string): Promise<MenuNode> {
  const url = `${HOST}/api/navigation/api/v1/U/${userHashId}/menu`;
  const res = await httpRequest(url, { headers: { authorization: `Bearer ${token}` } });
  if (res.status !== 200) {
    throw new Error(`menu fetch failed: ${res.status} ${res.body.slice(0, 200)}`);
  }
  return JSON.parse(res.body);
}

function normaliseSlug(s: string): string {
  return s.toLowerCase().replace(/[\s-]+/g, '_');
}

function findNodeById(tree: MenuNode | MenuNode[], id: string): MenuNode | null {
  const stack: MenuNode[] = Array.isArray(tree) ? [...tree] : [tree];
  while (stack.length) {
    const n = stack.pop()!;
    if (n.id === id) return n;
    if (n.children) stack.push(...n.children);
  }
  return null;
}

function collectGroupChildren(moduleNode: MenuNode): { groups: string[]; items: Record<string, string[]> } {
  const groups: string[] = [];
  const items: Record<string, string[]> = {};
  const children = moduleNode.children || [];
  for (const child of children) {
    // The child can be either:
    //   (a) a "group" node (label = Guide / Setup / Data / Deployment / etc.) with its own children
    //   (b) a leaf with a route directly under the module (legacy / flat)
    const labelKey = (child.label || child.slug || child.id || '').toLowerCase();
    if (child.children && child.children.length > 0) {
      // group
      const groupKey = inferGroupKey(labelKey, child.id);
      groups.push(groupKey);
      items[groupKey] = items[groupKey] || [];
      for (const leaf of child.children) {
        const leafSlug = inferLeafSlug(leaf);
        if (leafSlug) items[groupKey].push(leafSlug);
      }
    } else {
      // leaf directly under module — try to bucket via id/route hint
      const leafSlug = inferLeafSlug(child);
      const groupKey = inferGroupKeyFromLeaf(child);
      if (groupKey && leafSlug) {
        if (!groups.includes(groupKey)) groups.push(groupKey);
        items[groupKey] = items[groupKey] || [];
        items[groupKey].push(leafSlug);
      }
    }
  }
  return { groups, items };
}

function inferGroupKey(label: string, id?: string): string {
  if (label.includes('guide')) return 'guide';
  if (label.includes('setup')) return 'setup';
  if (label.includes('deploy')) return 'deployment';
  if (label.includes('data') || label.includes('manage')) return 'data';
  if (label.includes('demo')) return 'demo';
  if (label.includes('config')) return 'config';
  if (label.includes('help')) return 'help';
  if (label.includes('ops') || label.includes('operations')) return 'operations';
  // fallback: try id suffix
  if (id) {
    if (id.endsWith('-guide')) return 'guide';
    if (id.endsWith('-setup')) return 'setup';
    if (id.endsWith('-deployments') || id.endsWith('-deployment')) return 'deployment';
  }
  return label || 'unknown';
}

function inferGroupKeyFromLeaf(leaf: MenuNode): string | null {
  const id = leaf.id || '';
  const route = leaf.route || leaf.feRoute || '';
  if (id.endsWith('-setup') || /\/setup(\/|$)/.test(route)) return 'setup';
  if (id.endsWith('-deployments') || id.endsWith('-deployment') || /\/deployment/.test(route)) return 'deployment';
  if (/\/guide\//.test(route)) return 'guide';
  // generic data
  if (/\/(users|organizations|roles|privileges|menus|routes|topics|events|logs|tokens|list|audit)(\/|$)/.test(route)) return 'data';
  return 'data';
}

function inferLeafSlug(leaf: MenuNode): string | null {
  // Prefer last path component of route, fallback to id suffix
  const route = leaf.route || leaf.feRoute;
  if (route) {
    const parts = route.replace(/\/$/, '').split('/');
    return parts[parts.length - 1] || null;
  }
  const id = leaf.id || '';
  const m = id.match(/-([^-]+)$/);
  return m ? m[1] : null;
}

// ---------- main validation ----------

interface RequiredItem {
  group: string;
  item: string;
}

function extractRequiredItems(spec: ModuleSpec): { required: RequiredItem[]; optional: RequiredItem[] } {
  const required: RequiredItem[] = [];
  const optional: RequiredItem[] = [];
  for (const group of spec.required_groups || []) {
    const reqKey = `required_${group}_items`;
    const optKey = `optional_${group}_items`;
    for (const item of (spec[reqKey] as string[]) || []) required.push({ group, item });
    for (const item of (spec[optKey] as string[]) || []) optional.push({ group, item });
  }
  for (const group of spec.optional_groups || []) {
    const reqKey = `required_${group}_items`;
    const optKey = `optional_${group}_items`;
    // items declared under an optional group are themselves optional
    for (const item of (spec[reqKey] as string[]) || []) optional.push({ group, item });
    for (const item of (spec[optKey] as string[]) || []) optional.push({ group, item });
  }
  return { required, optional };
}

function validateModule(
  moduleKey: string,
  spec: ModuleSpec,
  menuTree: MenuNode,
): ModuleResult {
  const node = findNodeById(menuTree, spec.menuId);
  const expected_required_items: Record<string, string[]> = {};
  const expected_optional_items: Record<string, string[]> = {};
  for (const g of spec.required_groups || []) {
    expected_required_items[g] = (spec[`required_${g}_items`] as string[]) || [];
  }
  for (const g of spec.optional_groups || []) {
    expected_optional_items[g] = (spec[`optional_${g}_items`] as string[]) || [];
  }

  const result: ModuleResult = {
    module: moduleKey,
    menuId: spec.menuId,
    feRoute: spec.feRoute,
    expected: {
      required_groups: spec.required_groups || [],
      required_items: expected_required_items,
      optional_groups: spec.optional_groups || [],
      optional_items: expected_optional_items,
    },
    actual: {
      found_in_menu: !!node,
      groups: [],
      items: {},
    },
    missing_required: [],
    missing_optional: [],
    pass: true,
  };

  if (!node) {
    result.missing_required.push(`menuId:${spec.menuId} (module not registered in live menu)`);
    result.pass = false;
    return result;
  }

  const collected = collectGroupChildren(node);
  result.actual.groups = collected.groups;
  result.actual.items = collected.items;

  // S.4: required_groups
  for (const reqG of spec.required_groups || []) {
    if (!collected.groups.includes(reqG)) {
      result.missing_required.push(`group:${reqG}`);
    }
  }
  // S.5: required items per group
  const { required, optional } = extractRequiredItems(spec);
  for (const ri of required) {
    const gItems = (collected.items[ri.group] || []).map(normaliseSlug);
    if (!gItems.includes(normaliseSlug(ri.item))) {
      result.missing_required.push(`${ri.group}/${ri.item}`);
    }
  }
  // S.6: optional
  for (const oi of optional) {
    const gItems = (collected.items[oi.group] || []).map(normaliseSlug);
    if (!gItems.includes(normaliseSlug(oi.item))) {
      result.missing_optional.push(`${oi.group}/${oi.item}`);
    }
  }

  result.pass = result.missing_required.length === 0;
  return result;
}

// ---------- runner ----------

async function main() {
  console.log(`[section-s] env=${ENV} host=${HOST} cycle=${CYCLE}`);
  console.log(`[section-s] spec=${SPEC_PATH}`);

  // S.1: spec parses
  if (!fs.existsSync(SPEC_PATH)) {
    console.error(`FATAL: spec missing: ${SPEC_PATH}`);
    process.exit(2);
  }
  const spec: Spec = JSON.parse(fs.readFileSync(SPEC_PATH, 'utf-8'));
  const moduleKeys = Object.keys(spec.modules).filter((k) => !k.startsWith('_'));
  console.log(`[section-s] spec loaded: ${moduleKeys.length} modules declared`);

  // validate groupKeys allow-list
  const allowedGroups = new Set(spec.groupKeys.values);
  for (const k of moduleKeys) {
    const m = spec.modules[k] as ModuleSpec;
    for (const g of m.required_groups || []) {
      if (!allowedGroups.has(g)) {
        console.error(`FATAL S.1: module ${k} declares unknown required_group '${g}'`);
        process.exit(2);
      }
    }
  }

  // S.0 / S.2: login + fetch menu
  let token: string;
  let userHashId: string;
  let menuTree: MenuNode;
  try {
    const creds = readSecrets();
    // If no email provided, fall back to userHashId-based admin login endpoint
    const loginIdentifier = creds.email || creds.userHashId || '';
    const login_res = await login(loginIdentifier, creds.password);
    token = login_res.token;
    userHashId = login_res.userHashId;
    console.log(`[section-s] logged in as ${loginIdentifier} → userHashId=${userHashId}`);
    menuTree = await fetchMenu(token, userHashId);
    console.log(`[section-s] menu fetched, root children=${(menuTree as any).children?.length || 0}`);
  } catch (err: any) {
    console.error(`FATAL S.00/S.2: ${err.message}`);
    // Emit a stub report so the cycle log can still ingest something
    fs.mkdirSync(OUT_DIR, { recursive: true });
    fs.writeFileSync(
      path.join(OUT_DIR, 'section-s-report.json'),
      JSON.stringify(
        { ts: TIMESTAMP, env: ENV, error: err.message, modules: [] },
        null,
        2,
      ),
    );
    process.exit(2);
  }

  // S.3 / S.4 / S.5 / S.6: walk each module
  const results: ModuleResult[] = [];
  for (const k of moduleKeys) {
    const m = spec.modules[k] as ModuleSpec;
    if (!m.menuId) {
      console.warn(`[section-s] WARN: module ${k} has no menuId — skipping`);
      continue;
    }
    results.push(validateModule(k, m, menuTree));
  }

  // S.8: spec coverage report
  const liveModuleIds = new Set<string>();
  (function collect(n: MenuNode) {
    if (n.id && (n.id.startsWith('core-') || n.id.startsWith('cap-') || n.id.startsWith('biz-') || n.id.startsWith('ai-'))) {
      liveModuleIds.add(n.id);
    }
    if (n.children) n.children.forEach(collect);
  })(menuTree as MenuNode);
  const specMenuIds = new Set(moduleKeys.map((k) => (spec.modules[k] as ModuleSpec).menuId));
  const liveButNotInSpec = [...liveModuleIds].filter((id) => !specMenuIds.has(id));

  // ---------- summary ----------
  const total = results.length;
  const passed = results.filter((r) => r.pass).length;
  const failed = total - passed;
  const totalMissingRequired = results.reduce((a, r) => a + r.missing_required.length, 0);
  const totalMissingOptional = results.reduce((a, r) => a + r.missing_optional.length, 0);

  console.log('');
  console.log('==== Section S — Module Structure Validation ====');
  console.log(`Modules in spec     : ${total}`);
  console.log(`Modules pass        : ${passed}`);
  console.log(`Modules fail        : ${failed}`);
  console.log(`Missing required    : ${totalMissingRequired}`);
  console.log(`Missing optional    : ${totalMissingOptional}`);
  console.log(`Live but not in spec: ${liveButNotInSpec.length}`);
  console.log('');
  console.log('Per-module:');
  console.log('module                      | pass | miss_req | miss_opt');
  console.log('----------------------------|------|----------|----------');
  for (const r of results) {
    const tag = r.pass ? '  OK ' : ' FAIL';
    console.log(
      `${r.module.padEnd(28)}| ${tag} | ${String(r.missing_required.length).padStart(8)} | ${String(r.missing_optional.length).padStart(8)}`,
    );
  }
  if (liveButNotInSpec.length) {
    console.log('');
    console.log('Live menu modules NOT declared in spec (S.8 gap):');
    for (const id of liveButNotInSpec) console.log(`  - ${id}`);
  }

  // ---------- write report ----------
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const report = {
    ts: TIMESTAMP,
    env: ENV,
    host: HOST,
    cycle: CYCLE,
    spec_version: spec.version,
    summary: {
      total_modules: total,
      pass: passed,
      fail: failed,
      missing_required_total: totalMissingRequired,
      missing_optional_total: totalMissingOptional,
      live_but_not_in_spec: liveButNotInSpec.length,
    },
    modules: results,
    live_but_not_in_spec: liveButNotInSpec,
  };
  const reportPath = path.join(OUT_DIR, 'section-s-report.json');
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  console.log('');
  console.log(`[section-s] report → ${reportPath}`);

  // exit code: non-zero iff any required missing
  if (failed > 0 || totalMissingRequired > 0) {
    console.log(`[section-s] EXIT 1 — ${failed} module(s) missing required structure`);
    process.exit(1);
  }
  console.log(`[section-s] EXIT 0 — all required structure satisfied`);
  process.exit(0);
}

main().catch((err) => {
  console.error('FATAL unhandled:', err);
  process.exit(2);
});
