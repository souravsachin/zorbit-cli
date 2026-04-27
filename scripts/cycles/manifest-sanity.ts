#!/usr/bin/env node
/**
 * scripts/cycles/manifest-sanity.ts
 *
 * Validates a module's `zorbit-module-manifest.proposed.json` (or
 * `zorbit-module-manifest.json`) against the canonical contract in
 * 00_docs/platform/MANIFEST-V2-CANONICAL.md.
 *
 * Usage:
 *   npx ts-node scripts/cycles/manifest-sanity.ts <repo-path>
 *   npx ts-node scripts/cycles/manifest-sanity.ts <repo-path> --json
 *
 * Exit codes:
 *   0  all 🔴 (blockers) PASS — module is v2-conformant
 *   1  one or more 🔴 FAIL
 *   2  manifest file missing or unparseable
 *
 * Output:
 *   stdout: human-readable per-gate pass/fail/warn
 *   stderr: warnings (non-blockers)
 *   /tmp/manifest-sanity-<moduleId>.json: machine-readable report
 */

import * as fs from 'fs';
import * as path from 'path';

type Severity = 'blocker' | 'warn';
type Status   = 'pass' | 'fail' | 'na';

interface GateResult {
  id:        string;          // e.g. "MN.04"
  desc:      string;
  severity:  Severity;
  status:    Status;
  detail?:   string;
}

interface Report {
  repoPath:    string;
  moduleId?:   string;
  manifestPath:string;
  gates:       GateResult[];
  blockerFails: number;
  warnFails:   number;
  totalGates:  number;
  result:      'PASS' | 'FAIL';
}

const CANONICAL_GROUP_KEYS = new Set(['guide','ops','admin','db','demo','help']);
const CANONICAL_SCAFFOLDS  = new Set([
  'core_platform_services','platform_capabilities','business',
  'agentic_calling','support_center','user_profile','developer_center',
]);
const CANONICAL_MODULE_TYPES = new Set(['app','cor','pfs','tpm','sdk','ext','ai']);
const CANONICAL_GUIDE_ITEMS  = ['intro','presentation','lifecycle','videos','resources','pricing'];
const CANONICAL_DB_ITEMS     = ['shell','backup','restore','seeding'];
const CANONICAL_DB_OP_KEYS   = ['shell','backup','restore','seedSystemMin','seedDemoData','flushDemoData','flushAllData','list'];
const CANONICAL_SCOPES       = new Set(['G','O','U','D']);
const CANONICAL_DB_TYPES     = new Set(['postgresql','mongodb','redis','kafka','none']);
const FORBIDDEN_FIELDS_TOP   = ['moduleName','description','owner','icon','color','frontend','database','dashboard','reporting','seeding','analytics','privileges','pii','audit','manifestUrl','seed'];
const FE_ROUTE_RE  = /^\/m\/[a-z0-9_-]+\/[a-z0-9_-]+\/[a-z0-9_-]+$/;
const BE_ROUTE_RE  = /^\/api\/[a-z0-9_-]+\/api\/v1\/[GODU]\//;
const SLUG_RE      = /^[a-z0-9_-]+$/;
const FORBIDDEN_LABEL_KEYS_AT_STRUCT = ['label']; // only allowed inside manifest-content/pages/*.json

function pass(id: string, desc: string, severity: Severity = 'blocker'): GateResult {
  return { id, desc, severity, status: 'pass' };
}
function fail(id: string, desc: string, detail: string, severity: Severity = 'blocker'): GateResult {
  return { id, desc, severity, status: 'fail', detail };
}
function na(id: string, desc: string, detail: string): GateResult {
  return { id, desc, severity: 'blocker', status: 'na', detail };
}

function findManifest(repoPath: string): string | null {
  const candidates = [
    path.join(repoPath, 'zorbit-module-manifest.proposed.json'),
    path.join(repoPath, 'zorbit-module-manifest.json'),
  ];
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return null;
}

function readJson<T = any>(p: string): T {
  return JSON.parse(fs.readFileSync(p, 'utf-8')) as T;
}

function existsRel(repoPath: string, relSrc: string): boolean {
  // relSrc looks like "./manifest-content/guide/intro.md"; resolve against repoPath
  const cleaned = relSrc.replace(/^\.\//, '');
  return fs.existsSync(path.join(repoPath, cleaned));
}

function existsLangPath(repoPath: string, srcPath: string, lang: string): boolean {
  // Convert "./manifest-content/guide/intro.md" → "./manifest-content/<lang>/guide/intro.md"
  if (!srcPath.startsWith('./manifest-content/')) return false;
  const tail = srcPath.replace(/^\.\/manifest-content\//, '');
  return fs.existsSync(path.join(repoPath, 'manifest-content', lang, tail));
}

function deepHasKeyAnywhere(obj: any, keys: string[]): { found: string; path: string } | null {
  function walk(v: any, p: string): { found: string; path: string } | null {
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      for (const k of Object.keys(v)) {
        if (keys.includes(k)) return { found: k, path: `${p}.${k}` };
        const sub = walk(v[k], `${p}.${k}`);
        if (sub) return sub;
      }
    } else if (Array.isArray(v)) {
      for (let i = 0; i < v.length; i++) {
        const sub = walk(v[i], `${p}[${i}]`);
        if (sub) return sub;
      }
    }
    return null;
  }
  return walk(obj, '');
}

function findStringMatching(obj: any, regex: RegExp, p = ''): { value: string; path: string } | null {
  if (typeof obj === 'string') {
    if (regex.test(obj)) return { value: obj, path: p };
    return null;
  }
  if (Array.isArray(obj)) {
    for (let i = 0; i < obj.length; i++) {
      const sub = findStringMatching(obj[i], regex, `${p}[${i}]`);
      if (sub) return sub;
    }
    return null;
  }
  if (obj && typeof obj === 'object') {
    for (const k of Object.keys(obj)) {
      const sub = findStringMatching(obj[k], regex, `${p}.${k}`);
      if (sub) return sub;
    }
  }
  return null;
}

function validate(repoPath: string): Report {
  const r: Report = {
    repoPath,
    manifestPath: '',
    gates: [],
    blockerFails: 0,
    warnFails: 0,
    totalGates: 0,
    result: 'PASS',
  };

  const manifestPath = findManifest(repoPath);
  if (!manifestPath) {
    r.gates.push(fail('MN.00', 'manifest file present', `No zorbit-module-manifest.json found at ${repoPath}`));
    r.blockerFails++;
    r.result = 'FAIL';
    return r;
  }
  r.manifestPath = manifestPath;

  let m: any;
  try {
    m = readJson(manifestPath);
  } catch (e: any) {
    r.gates.push(fail('MN.00', 'manifest parses', `JSON parse error: ${e.message}`));
    r.blockerFails++;
    r.result = 'FAIL';
    return r;
  }
  r.gates.push(pass('MN.00', 'manifest file exists + parses'));
  r.moduleId = m.moduleId;

  // MN.01 manifestVersion === "2.0"
  r.gates.push(m.manifestVersion === '2.0'
    ? pass('MN.01', 'manifestVersion === "2.0"')
    : fail('MN.01', 'manifestVersion === "2.0"', `got: ${m.manifestVersion}`));

  // MN.02 moduleId / moduleType / version
  const m02parts: string[] = [];
  if (typeof m.moduleId !== 'string' || !m.moduleId.trim()) m02parts.push('moduleId missing');
  if (!CANONICAL_MODULE_TYPES.has(m.moduleType)) m02parts.push(`moduleType=${m.moduleType} not in {${[...CANONICAL_MODULE_TYPES].join(',')}}`);
  if (typeof m.version !== 'string') m02parts.push('version missing');
  r.gates.push(m02parts.length === 0
    ? pass('MN.02', 'moduleId / moduleType / version valid')
    : fail('MN.02', 'moduleId / moduleType / version valid', m02parts.join('; ')));

  // MN.03 placement.scaffold canonical slug
  const placement = m.placement ?? {};
  const scaffoldOk = typeof placement.scaffold === 'string' && CANONICAL_SCAFFOLDS.has(placement.scaffold);
  const sortOrderOk = Number.isInteger(placement.scaffoldSortOrder);
  let m03parts: string[] = [];
  if (!scaffoldOk) m03parts.push(`scaffold=${placement.scaffold} not in canonical slugs`);
  if (!sortOrderOk) m03parts.push('scaffoldSortOrder not integer');
  if (placement.scaffold === 'business') {
    const ed = placement.edition;
    if (!ed || typeof ed !== 'object' || typeof ed.name !== 'string' || !SLUG_RE.test(ed.name)) m03parts.push('edition.name missing or not slug');
    if (typeof placement.businessLine !== 'string' || !SLUG_RE.test(placement.businessLine)) m03parts.push('businessLine missing or not slug');
    if (typeof placement.capabilityArea !== 'string' || !SLUG_RE.test(placement.capabilityArea)) m03parts.push('capabilityArea not slug');
  }
  r.gates.push(m03parts.length === 0
    ? pass('MN.03', 'placement valid')
    : fail('MN.03', 'placement valid', m03parts.join('; ')));

  // MN.04 navigation.sections[].id ∈ canonical group keys
  const sections = m.navigation?.sections ?? [];
  if (!Array.isArray(sections)) {
    r.gates.push(fail('MN.04', 'nav sections array', 'not an array'));
  } else {
    const bad = sections.filter((s: any) => !CANONICAL_GROUP_KEYS.has(s.id));
    r.gates.push(bad.length === 0
      ? pass('MN.04', `every section.id ∈ {${[...CANONICAL_GROUP_KEYS].join(',')}}`)
      : fail('MN.04', `every section.id ∈ {${[...CANONICAL_GROUP_KEYS].join(',')}}`, `bad: ${bad.map((s: any) => s.id).join(',')}`));
  }

  // MN.05 every nav item has feComponent
  let mn05Bad: string[] = [];
  let allItems: any[] = [];
  for (const s of sections) {
    if (!Array.isArray(s.items)) continue;
    for (const it of s.items) {
      allItems.push({ section: s.id, item: it });
      if (typeof it.feComponent !== 'string' || !it.feComponent.trim()) mn05Bad.push(`${s.id}/${it.id}`);
    }
  }
  r.gates.push(mn05Bad.length === 0
    ? pass('MN.05', 'every nav item has feComponent')
    : fail('MN.05', 'every nav item has feComponent', `missing: ${mn05Bad.join(',')}`));

  // MN.06 nav item feRoute matches /m/<m>/<group>/<item>
  let mn06Bad: string[] = [];
  for (const { section, item } of allItems) {
    if (typeof item.feRoute !== 'string' || !FE_ROUTE_RE.test(item.feRoute)) mn06Bad.push(`${section}/${item.id}=${item.feRoute}`);
  }
  r.gates.push(mn06Bad.length === 0
    ? pass('MN.06', 'every nav item feRoute matches /m/<m>/<group>/<item>')
    : fail('MN.06', 'every nav item feRoute matches', `bad: ${mn06Bad.join(' | ')}`));

  // MN.07 item.id appears in feRoute
  let mn07Bad: string[] = [];
  for (const { section, item } of allItems) {
    if (typeof item.feRoute === 'string' && typeof item.id === 'string' && !item.feRoute.endsWith(`/${item.id}`)) {
      mn07Bad.push(`${section}/${item.id}=${item.feRoute}`);
    }
  }
  r.gates.push(mn07Bad.length === 0
    ? pass('MN.07', 'item.id appears verbatim at end of feRoute')
    : fail('MN.07', 'item.id appears verbatim at end of feRoute', mn07Bad.join(' | ')));

  // MN.08 guide section has the 6 canonical items
  const guideSection = sections.find((s: any) => s.id === 'guide');
  if (!guideSection) {
    r.gates.push(fail('MN.08', 'guide section has 6 canonical items', 'guide section missing'));
  } else {
    const guideIds = new Set((guideSection.items ?? []).map((it: any) => it.id));
    const missing = CANONICAL_GUIDE_ITEMS.filter(g => !guideIds.has(g));
    const extra   = [...guideIds].filter(g => !CANONICAL_GUIDE_ITEMS.includes(g as string));
    const parts: string[] = [];
    if (missing.length) parts.push(`missing: ${missing.join(',')}`);
    if (extra.length)   parts.push(`extra: ${extra.join(',')}`);
    r.gates.push(parts.length === 0
      ? pass('MN.08', 'guide has exactly intro/presentation/lifecycle/videos/resources/pricing')
      : fail('MN.08', 'guide has exactly intro/presentation/lifecycle/videos/resources/pricing', parts.join('; ')));
  }

  // MN.09 every $src ref resolves under en/
  // collect all $src strings
  function collectSrcs(v: any, srcs: string[]) {
    if (Array.isArray(v)) v.forEach(x => collectSrcs(x, srcs));
    else if (v && typeof v === 'object') {
      if (typeof v.$src === 'string') srcs.push(v.$src);
      Object.values(v).forEach(x => collectSrcs(x, srcs));
    }
  }
  const srcs: string[] = [];
  collectSrcs(m, srcs);
  const mn09Bad = srcs.filter(s => !s.startsWith('./manifest-content/'));
  r.gates.push(mn09Bad.length === 0
    ? pass('MN.09', `every $src starts with ./manifest-content/ (${srcs.length} refs)`)
    : fail('MN.09', 'every $src starts with ./manifest-content/', `bad: ${mn09Bad.join(',')}`));

  // MN.11 all 6 guide blocks present
  const guide = m.guide ?? {};
  const requiredGuide = ['intro','slides','lifecycle','videos','resources','pricing'];
  const missingGuide = requiredGuide.filter(k => !(k in guide));
  r.gates.push(missingGuide.length === 0
    ? pass('MN.11', `guide.{${requiredGuide.join(',')}} all present`)
    : fail('MN.11', 'guide blocks present', `missing: ${missingGuide.join(',')}`));

  // MN.12 slides.decks is OBJECT
  if (guide.slides) {
    const decks = guide.slides.decks;
    const ok = decks && typeof decks === 'object' && (decks.$src || Object.keys(decks).length > 0);
    r.gates.push(ok
      ? pass('MN.12', 'guide.slides.decks is OBJECT (not array)')
      : fail('MN.12', 'guide.slides.decks is OBJECT', 'missing or wrong shape'));
  }

  // MN.13 videos.playlists is OBJECT
  if (guide.videos) {
    const pls = guide.videos.playlists;
    const ok = pls && typeof pls === 'object' && (pls.$src || Object.keys(pls).length > 0);
    r.gates.push(ok
      ? pass('MN.13', 'guide.videos.playlists is OBJECT')
      : fail('MN.13', 'guide.videos.playlists is OBJECT', 'missing or wrong shape'));
  }

  // MN.14 deployments.health.beRoute non-empty + matches BE regex
  const dep = m.deployments ?? {};
  const healthBe = dep.health?.beRoute;
  r.gates.push(typeof healthBe === 'string' && BE_ROUTE_RE.test(healthBe)
    ? pass('MN.14', 'deployments.health.beRoute matches BE regex')
    : fail('MN.14', 'deployments.health.beRoute matches BE regex', `got: ${healthBe}`));

  // MN.15 deployments.show is boolean
  r.gates.push(typeof dep.show === 'boolean'
    ? pass('MN.15', 'deployments.show is boolean')
    : fail('MN.15', 'deployments.show is boolean', `got: ${typeof dep.show}`));

  // MN.16/17/18 db.* (only if module owns DB — db block present)
  const db = m.db;
  const dbSection = sections.find((s: any) => s.id === 'db');
  if (db) {
    // MN.16 alias slug + type allowed
    let mn16parts: string[] = [];
    if (typeof db.alias !== 'string' || !SLUG_RE.test(db.alias)) mn16parts.push(`alias=${db.alias} not slug`);
    if (!CANONICAL_DB_TYPES.has(db.type)) mn16parts.push(`type=${db.type} not in {${[...CANONICAL_DB_TYPES].join(',')}}`);
    r.gates.push(mn16parts.length === 0
      ? pass('MN.16', 'db.alias slug + db.type ∈ allowed set')
      : fail('MN.16', 'db.alias + db.type', mn16parts.join('; ')));

    // MN.17 db.collections is string[] of slugs
    if (!Array.isArray(db.collections)) {
      r.gates.push(fail('MN.17', 'db.collections is string[]', 'not an array'));
    } else {
      const bad = db.collections.filter((c: any) => typeof c !== 'string' || !/^[a-z0-9_]+$/.test(c));
      r.gates.push(bad.length === 0
        ? pass('MN.17', `db.collections is string[] of slugs (${db.collections.length})`)
        : fail('MN.17', 'db.collections is string[] of slugs', `bad: ${bad.map((x: any) => JSON.stringify(x)).join(',')}`));
    }

    // MN.18 db.operations declares all 8 ops
    const ops = db.operations ?? {};
    const missingOps = CANONICAL_DB_OP_KEYS.filter(k => !ops[k]);
    if (missingOps.length) {
      r.gates.push(fail('MN.18', `db.operations declares all 8 ops`, `missing: ${missingOps.join(',')}`));
    } else {
      let badOps: string[] = [];
      for (const k of CANONICAL_DB_OP_KEYS) {
        const op = ops[k];
        if (!op.beRoute || !BE_ROUTE_RE.test(op.beRoute)) badOps.push(`${k}.beRoute`);
        if (!CANONICAL_SCOPES.has(op.scope)) badOps.push(`${k}.scope=${op.scope}`);
        if (!['POST','GET','DELETE','PUT','PATCH'].includes(op.method)) badOps.push(`${k}.method=${op.method}`);
        if (typeof op.sse !== 'boolean') badOps.push(`${k}.sse=${typeof op.sse}`);
      }
      r.gates.push(badOps.length === 0
        ? pass('MN.18', 'every db.operations entry has valid beRoute/scope/method/sse')
        : fail('MN.18', 'db.operations entries valid', `bad: ${badOps.join(',')}`));
    }

    // MN db nav section: 4 fixed items
    if (!dbSection) {
      r.gates.push(fail('MN.18b', 'db-owning module has db nav section', 'missing'));
    } else {
      const dbItemIds = new Set((dbSection.items ?? []).map((it: any) => it.id));
      const missingDbItems = CANONICAL_DB_ITEMS.filter(g => !dbItemIds.has(g));
      r.gates.push(missingDbItems.length === 0
        ? pass('MN.18b', `db nav section has [${CANONICAL_DB_ITEMS.join(',')}]`)
        : fail('MN.18b', 'db nav section has 4 fixed items', `missing: ${missingDbItems.join(',')}`));
    }
  } else {
    r.gates.push(na('MN.16', 'db block', 'module does not own DB (no db block); skipping MN.16/17/18'));
  }

  // MN.19 backend.baseUrl localhost; apiPrefix has no scope segment
  const be = m.backend ?? {};
  const baseOk = typeof be.baseUrl === 'string' && /^https?:\/\/localhost:\d+$/.test(be.baseUrl);
  const apiOk  = typeof be.apiPrefix === 'string' && /^\/api\/[a-z0-9_-]+\/api\/v\d+$/.test(be.apiPrefix);
  let mn19parts: string[] = [];
  if (!baseOk) mn19parts.push(`baseUrl=${be.baseUrl}`);
  if (!apiOk)  mn19parts.push(`apiPrefix=${be.apiPrefix} (must end before scope segment)`);
  r.gates.push(mn19parts.length === 0
    ? pass('MN.19', 'backend.baseUrl localhost + apiPrefix slug-only')
    : fail('MN.19', 'backend.baseUrl + apiPrefix', mn19parts.join('; ')));

  // MN.20 NO https:// URLs anywhere
  const httpsHit = findStringMatching(m, /https?:\/\/(?!localhost)/);
  r.gates.push(!httpsHit
    ? pass('MN.20', 'no https:// (env-specific) URLs in manifest')
    : fail('MN.20', 'no https:// URLs', `found at ${httpsHit.path}: ${httpsHit.value}`));

  // MN.21 NO manifestUrl field at any level
  const muHit = deepHasKeyAnywhere(m, ['manifestUrl']);
  r.gates.push(!muHit
    ? pass('MN.21', 'no manifestUrl field')
    : fail('MN.21', 'no manifestUrl field', `found at ${muHit.path}`));

  // MN.22 NO non-v2 vestige fields at top level
  const ftFound = FORBIDDEN_FIELDS_TOP.filter(k => k in m);
  r.gates.push(ftFound.length === 0
    ? pass('MN.22', 'no non-v2 vestige top-level fields')
    : fail('MN.22', 'no non-v2 vestige top-level fields', `found: ${ftFound.join(',')}`));

  // MN.23 no Material Symbols `_` style icon names (icons should be Lucide PascalCase)
  // Heuristic: any "icon" string that's all lowercase with _ probably Material; flag.
  function findMaterialIcons(obj: any, p = '', acc: string[] = []): string[] {
    if (Array.isArray(obj)) obj.forEach((x, i) => findMaterialIcons(x, `${p}[${i}]`, acc));
    else if (obj && typeof obj === 'object') {
      for (const k of Object.keys(obj)) {
        if (k === 'icon' && typeof obj[k] === 'string' && /^[a-z][a-z0-9_]*$/.test(obj[k])) {
          acc.push(`${p}.${k}=${obj[k]}`);
        }
        findMaterialIcons(obj[k], `${p}.${k}`, acc);
      }
    }
    return acc;
  }
  const matIcons = findMaterialIcons(m);
  r.gates.push(matIcons.length === 0
    ? pass('MN.23', 'no Material Symbols icons (Lucide only)')
    : fail('MN.23', 'no Material Symbols icons', matIcons.join(' | '), 'warn'));

  // MN.24 dependencies is string[]
  if ('dependencies' in m) {
    const ok = Array.isArray(m.dependencies) && m.dependencies.every((d: any) => typeof d === 'string');
    r.gates.push(ok
      ? pass('MN.24', 'dependencies is string[]')
      : fail('MN.24', 'dependencies is string[]', `got: ${typeof m.dependencies}`));
  }

  // MN.26 openForm action shape (when present)
  // Walk page files would be needed; for manifest-only, skip and check page files later.

  // MN.33 NO moduleName field
  r.gates.push(!('moduleName' in m)
    ? pass('MN.33', 'no moduleName field (label leak)')
    : fail('MN.33', 'no moduleName field', `value: ${m.moduleName}`));

  // MN.34 db.collections is string[] of slugs (already checked in MN.17 if db owned)

  // MN.35 NO `label` keys at structural level (placement / navigation / db)
  const labelInPlacement = deepHasKeyAnywhere(m.placement ?? {}, ['label']);
  const labelInNav       = deepHasKeyAnywhere(m.navigation ?? {}, ['label']);
  const labelInDb        = deepHasKeyAnywhere(m.db ?? {},        ['label']);
  const labelHits = [labelInPlacement, labelInNav, labelInDb].filter(Boolean) as { found: string; path: string }[];
  r.gates.push(labelHits.length === 0
    ? pass('MN.35', 'no `label` at structural level')
    : fail('MN.35', 'no `label` at structural level', labelHits.map(h => `placement/nav/db${h.path}`).join(' | ')));

  // MN.38 manifest-content/en/ exists (if any $src is declared)
  if (srcs.length > 0) {
    const enExists = fs.existsSync(path.join(repoPath, 'manifest-content', 'en'));
    r.gates.push(enExists
      ? pass('MN.38', 'manifest-content/en/ directory exists')
      : fail('MN.38', 'manifest-content/en/ directory exists', 'missing'));
  }

  // MN.42 every $src resolves under en/
  const mn42Bad = srcs.filter(s => !existsLangPath(repoPath, s, 'en') && !existsRel(repoPath, s));
  // existsRel covers errors.json which is at manifest-content/errors.json (no language; module-level catalogue)
  r.gates.push(mn42Bad.length === 0
    ? pass('MN.42', `every $src resolves under en/ or root (${srcs.length} refs)`)
    : fail('MN.42', 'every $src resolves under en/', `missing: ${mn42Bad.join(', ')}`));

  // MN.43 NO language field
  const langHit = deepHasKeyAnywhere(m, ['language']);
  r.gates.push(!langHit
    ? pass('MN.43', 'no `language` field at any level')
    : fail('MN.43', 'no `language` field at any level', langHit.path));

  // MN.44 templates declarations have matching files
  const templates = m.templates;
  if (templates) {
    let mn44Bad: string[] = [];
    for (const kind of ['email','sms','push','pdf']) {
      const arr = templates[kind];
      if (!Array.isArray(arr)) continue;
      for (const id of arr) {
        const dir = path.join(repoPath, 'manifest-content', 'en', 'templates', kind);
        const matches = fs.existsSync(dir)
          ? fs.readdirSync(dir).some(f => f.startsWith(`${id}.`))
          : false;
        if (!matches) mn44Bad.push(`${kind}/${id}`);
      }
    }
    r.gates.push(mn44Bad.length === 0
      ? pass('MN.44', 'templates declarations resolve to files')
      : fail('MN.44', 'templates declarations resolve to files', `missing: ${mn44Bad.join(',')}`, 'warn'));
  }

  // MN.45 voice.prompts declarations have matching files
  if (m.voice?.prompts) {
    const arr: string[] = m.voice.prompts;
    let mn45Bad: string[] = [];
    for (const id of arr) {
      const f = path.join(repoPath, 'manifest-content', 'en', 'voice', 'prompts', `${id}.txt`);
      if (!fs.existsSync(f)) mn45Bad.push(id);
    }
    r.gates.push(mn45Bad.length === 0
      ? pass('MN.45', 'voice.prompts resolve to text files')
      : fail('MN.45', 'voice.prompts resolve to text files', `missing: ${mn45Bad.join(',')}`));
  }

  // MN.55 resources block
  if (m.resources) {
    if (!Array.isArray(m.resources)) {
      r.gates.push(fail('MN.55', 'resources is array', 'not an array'));
    } else {
      let mn55Bad: string[] = [];
      for (let i = 0; i < m.resources.length; i++) {
        const res = m.resources[i];
        if (!SLUG_RE.test(res.id)) mn55Bad.push(`#${i}.id=${res.id} not slug`);
        if (!['source','cache'].includes(res.role)) mn55Bad.push(`#${i}.role=${res.role}`);
        if (typeof res.primaryKey !== 'string' || !res.primaryKey.trim()) mn55Bad.push(`#${i}.primaryKey missing`);
        if (!Array.isArray(res.attributes)) mn55Bad.push(`#${i}.attributes not array`);
        if (!Array.isArray(res.exportedTo)) mn55Bad.push(`#${i}.exportedTo not array`);
      }
      r.gates.push(mn55Bad.length === 0
        ? pass('MN.55', `resources block valid (${m.resources.length} resources)`)
        : fail('MN.55', 'resources block valid', mn55Bad.join('; ')));
    }
  }

  // ── tally ──
  for (const g of r.gates) {
    r.totalGates++;
    if (g.status === 'fail') {
      if (g.severity === 'blocker') r.blockerFails++;
      else r.warnFails++;
    }
  }
  r.result = r.blockerFails > 0 ? 'FAIL' : 'PASS';

  return r;
}

// ── CLI ──
const args = process.argv.slice(2);
if (args.length < 1) {
  console.error('usage: manifest-sanity.ts <repo-path> [--json]');
  process.exit(2);
}
const repoPath = path.resolve(args[0]);
const wantJson = args.includes('--json');
const report = validate(repoPath);

if (wantJson) {
  console.log(JSON.stringify(report, null, 2));
} else {
  console.log(`\n=== manifest-sanity — ${report.moduleId ?? '(no moduleId)'} ===`);
  console.log(`repo: ${repoPath}`);
  console.log(`manifest: ${report.manifestPath}\n`);
  for (const g of report.gates) {
    const icon = g.status === 'pass' ? '✅'
              : g.status === 'fail'  ? (g.severity === 'blocker' ? '❌' : '⚠️ ')
              : '➖';
    console.log(`  ${icon} ${g.id}  ${g.desc}${g.detail ? '  — ' + g.detail : ''}`);
  }
  console.log(`\nresult: ${report.result}  (blockers fail: ${report.blockerFails}, warns: ${report.warnFails}, total: ${report.totalGates})`);
}

const reportPath = `/tmp/manifest-sanity-${(report.moduleId ?? 'unknown').replace(/[^a-z0-9_-]/gi, '_')}.json`;
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
console.error(`report: ${reportPath}`);

process.exit(report.result === 'PASS' ? 0 : 1);
