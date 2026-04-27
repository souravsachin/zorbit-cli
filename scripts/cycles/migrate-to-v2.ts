#!/usr/bin/env node
/**
 * scripts/cycles/migrate-to-v2.ts
 *
 * Reads <repo>/zorbit-module-manifest.json (legacy), produces a
 * <repo>/zorbit-module-manifest.proposed.json (v2-conformant) and
 * scaffolds <repo>/manifest-content/en/* templates.
 *
 * Usage:
 *   npx ts-node scripts/cycles/migrate-to-v2.ts <repo-path> [--write]
 *
 * Without --write, prints the proposed manifest to stdout.
 * With --write, writes the .proposed.json + creates manifest-content/en/* stubs.
 */
import * as fs from 'fs';
import * as path from 'path';

const SLUG_TRANS_DIR = '/Users/s/workspace/zorbit/02_repos/zorbit-core/platform-spec/slug-translations';

function readJson<T = any>(p: string): T { return JSON.parse(fs.readFileSync(p, 'utf-8')); }
function existsRel(repo: string, rel: string) { return fs.existsSync(path.join(repo, rel)); }

function deriveModuleSlug(moduleId: string): string {
  return moduleId.replace(/^zorbit-(cor|app|pfs|ai|tpm)-/, '');
}

function detectModuleType(moduleId: string, oldM: any): string {
  if (oldM.moduleType && ['app','cor','pfs','tpm','ai','sdk','ext'].includes(oldM.moduleType)) return oldM.moduleType;
  if (moduleId.startsWith('zorbit-cor-')) return 'cor';
  if (moduleId.startsWith('zorbit-pfs-')) return 'pfs';
  if (moduleId.startsWith('zorbit-app-')) return 'app';
  if (moduleId.startsWith('zorbit-ai-'))  return 'ai';
  if (moduleId.startsWith('zorbit-tpm-')) return 'tpm';
  if (moduleId.includes('portal') || moduleId.includes('claims_intake') || moduleId.includes('prospect_portal')) return 'ext';
  return 'app';
}

function inferPort(oldM: any, moduleId: string): number {
  // try existing baseUrl
  const m = (oldM.backend?.baseUrl ?? oldM.baseUrl ?? '').match(/:(\d+)/);
  if (m) return parseInt(m[1], 10);
  // try ecosystem PORT env
  // fallback by module type
  if (moduleId.startsWith('zorbit-cor-')) return 3000;
  if (moduleId.startsWith('zorbit-pfs-')) return 3010;
  if (moduleId.startsWith('zorbit-app-')) return 3100;
  if (moduleId.startsWith('zorbit-ai-'))  return 3200;
  return 3000;
}

function loadSlugTranslations() {
  const enPath = path.join(SLUG_TRANS_DIR, 'en.json');
  if (fs.existsSync(enPath)) return readJson(enPath);
  return {};
}

function placementFor(moduleId: string, slugTrans: any): any {
  const aliases = slugTrans.moduleAlias ?? {};
  const a = aliases[moduleId];
  const slug = deriveModuleSlug(moduleId);
  if (!a) {
    // Best-effort guess
    return {
      scaffold: 'developer_center',
      scaffoldSortOrder: 70,
      capabilityArea: slug,
      sortOrder: 10,
    };
  }
  const out: any = {
    scaffold: a.scaffold,
    scaffoldSortOrder: scaffoldOrder(a.scaffold),
    capabilityArea: a.capabilityArea ?? slug,
    sortOrder: 10,
  };
  if (a.scaffold === 'business') {
    out.businessLine = a.businessLine ?? 'distribution';
    // edition: derive from moduleId slug heuristically — most are health insurance
    let edition = 'health_insurance';
    if (moduleId.includes('mi_')) edition = 'motor_insurance';
    if (moduleId.includes('hi_')) edition = 'health_insurance';
    if (moduleId.includes('manufacturing')) edition = 'health_insurance';     // demo edition fallback
    if (moduleId.includes('retail_banking')) edition = 'health_insurance';
    if (moduleId.includes('wealth')) edition = 'health_insurance';
    out.edition = {
      name: edition,
      category: 'insurer',
      categorySortOrder: 10,
      sortOrder: 10,
    };
  }
  return out;
}

function scaffoldOrder(scaffold: string): number {
  return {
    'core_platform_services': 10,
    'platform_capabilities': 20,
    'business': 30,
    'agentic_calling': 40,
    'support_center': 50,
    'user_profile': 60,
    'developer_center': 70,
  }[scaffold] ?? 99;
}

function scoringDb(oldM: any): { hasDb: boolean; type: string; alias: string; collections: string[] } {
  const dbBlock = oldM.db ?? oldM.database ?? {};
  const collections = (dbBlock.collections ?? dbBlock.tables ?? []).filter((c: any) => typeof c === 'string' || (c && c.id));
  const colSlugs = collections.map((c: any) => typeof c === 'string' ? c : c.id).filter(Boolean);
  const dbType = dbBlock.type ?? dbBlock.kind ?? 'postgresql';
  const moduleSlug = deriveModuleSlug(oldM.moduleId ?? '');
  const alias = dbBlock.alias ?? moduleSlug;
  const hasDb = !!(dbBlock.type || dbBlock.name || colSlugs.length > 0);
  return { hasDb, type: dbType.toLowerCase().replace(/^postgres$/, 'postgresql'), alias, collections: colSlugs };
}

function buildV2(oldM: any, slugTrans: any, repoPath: string): any {
  const moduleId   = oldM.moduleId;
  const moduleSlug = deriveModuleSlug(moduleId);
  const moduleType = detectModuleType(moduleId, oldM);
  const port       = inferPort(oldM, moduleId);
  const apiSlug    = moduleSlug.replace(/_/g, '_'); // already snake
  const placement  = placementFor(moduleId, slugTrans);
  const dbInfo     = scoringDb(oldM);

  // --- guide section is uniform
  const guideItems = ['intro','presentation','lifecycle','videos','resources','pricing'].map((id, i) => ({
    id,
    sortOrder:    i + 1,
    feRoute:      `/m/${moduleSlug}/guide/${id}`,
    feComponent:  ({ intro:'@platform:GuideIntroView', presentation:'@platform:GuideSlideDeck', lifecycle:'@platform:GuideLifecycle', videos:'@platform:GuideVideos', resources:'@platform:GuideResources', pricing:'@platform:GuidePricing' } as any)[id],
  }));

  // --- ops items: try to extract from existing nav OR existing endpoints
  let opsItems: any[] = [];
  const oldNav = oldM.navigation?.sections ?? oldM.nav?.sections ?? [];
  for (const sec of oldNav) {
    if ((sec.id ?? sec.label ?? '').toLowerCase().match(/data|ops|main/)) {
      for (const it of (sec.items ?? [])) {
        const slug = (it.id ?? it.label ?? '').toString().toLowerCase().replace(/[^a-z0-9_-]/g, '-').replace(/^-+|-+$/g,'');
        if (!slug) continue;
        opsItems.push({
          id: slug,
          sortOrder: opsItems.length + 1,
          feRoute: `/m/${moduleSlug}/ops/${slug}`,
          feComponent: 'zorbit-pfs-datatable:DataTable',
          feProps: { '$src': `./manifest-content/pages/${slug}.json` },
          privilege: it.privilege ?? `${apiSlug}.${slug.replace(/-/g,'_')}.read`,
        });
      }
    }
  }
  // If no ops detected, derive from db.collections
  if (opsItems.length === 0 && dbInfo.collections.length > 0) {
    opsItems = dbInfo.collections.slice(0, 5).map((c, i) => {
      const slug = c.replace(/_/g,'-');
      return {
        id: slug,
        sortOrder: i + 1,
        feRoute: `/m/${moduleSlug}/ops/${slug}`,
        feComponent: 'zorbit-pfs-datatable:DataTable',
        feProps: { '$src': `./manifest-content/pages/${slug}.json` },
        privilege: `${apiSlug}.${c}.read`,
      };
    });
  }

  // --- db section if hasDb
  const dbItems = ['shell','backup','restore','seeding'].map((id, i) => ({
    id,
    sortOrder: i + 1,
    feRoute: `/m/${moduleSlug}/db/${id}`,
    feComponent: ({ shell:'@platform:DbShell', backup:'@platform:DbBackup', restore:'@platform:DbRestore', seeding:'@platform:DbSeeding' } as any)[id],
    privilege: `${apiSlug}.db.${id}`,
  }));

  const sections: any[] = [
    { id: 'guide', sortOrder: 0, items: guideItems },
  ];
  if (opsItems.length > 0) sections.push({ id: 'ops', sortOrder: 10, items: opsItems });
  if (dbInfo.hasDb)         sections.push({ id: 'db',  sortOrder: 30, items: dbItems });

  // --- guide $src refs
  const guide = {
    intro:     { '$src': './manifest-content/guide/intro.md' },
    slides:    { decks:     { '$src': './manifest-content/guide/slides/index.json' } },
    lifecycle: { '$src': './manifest-content/guide/lifecycle.json' },
    videos:    { playlists: { '$src': './manifest-content/guide/videos/index.json' } },
    resources: { '$src': './manifest-content/guide/resources.json' },
    pricing:   { '$src': './manifest-content/guide/pricing.json' },
  };

  // --- deployments — ALWAYS use canonical route, ignore legacy non-conformant values
  const deployments: any = {
    show: oldM.deployments?.show !== false,
    health: { beRoute: `/api/${apiSlug}/api/v1/G/health` },
  };

  // --- db block
  const out: any = {
    manifestVersion: '2.0',
    moduleId,
    moduleType,
    version: oldM.version ?? '0.1.0',
    placement,
    registration: { kafkaTopic: 'platform-module-announcements' },
    navigation: { sections },
    guide,
    deployments,
  };

  if (dbInfo.hasDb) {
    out.db = {
      alias: dbInfo.alias,
      type:  dbInfo.type,
      collections: dbInfo.collections.length > 0 ? dbInfo.collections : [moduleSlug],
      operations: {
        shell:         { beRoute: `/api/${apiSlug}/api/v1/G/db/shell`,        scope: 'G', method: 'POST',   sse: false },
        backup:        { beRoute: `/api/${apiSlug}/api/v1/G/db/backup`,       scope: 'G', method: 'POST',   sse: true  },
        restore:       { beRoute: `/api/${apiSlug}/api/v1/G/db/restore`,      scope: 'G', method: 'POST',   sse: true  },
        seedSystemMin: { beRoute: `/api/${apiSlug}/api/v1/G/seed/system-min`, scope: 'G', method: 'POST',   sse: true  },
        seedDemoData:  { beRoute: `/api/${apiSlug}/api/v1/G/seed/demo`,       scope: 'G', method: 'POST',   sse: true  },
        flushDemoData: { beRoute: `/api/${apiSlug}/api/v1/G/seed/demo`,       scope: 'G', method: 'DELETE', sse: true  },
        flushAllData:  { beRoute: `/api/${apiSlug}/api/v1/G/seed/all`,        scope: 'G', method: 'DELETE', sse: true  },
        list:          { beRoute: `/api/${apiSlug}/api/v1/G/db/list`,         scope: 'G', method: 'GET',    sse: false },
      },
    };
  }

  // --- backend
  out.backend = {
    baseUrl: `http://localhost:${port}`,
    apiPrefix: `/api/${apiSlug}/api/v1`,
  };

  // --- events
  const oldEvents = oldM.events ?? {};
  const pubs = Array.isArray(oldEvents.publishes) ? oldEvents.publishes : [];
  const subs = Array.isArray(oldEvents.subscribes) ? oldEvents.subscribes : [];
  out.events = { publishes: pubs, subscribes: subs };

  // --- errors $src
  out.errors = { '$src': './manifest-content/errors.json' };

  // --- dependencies
  let deps = oldM.dependencies;
  if (Array.isArray(deps)) {
    out.dependencies = deps.filter((x: any) => typeof x === 'string');
  } else if (deps && typeof deps === 'object') {
    out.dependencies = [...(deps.platform ?? []), ...(deps.business ?? [])].filter(Boolean);
  } else {
    out.dependencies = ['zorbit-cor-event_bus'];
  }

  return out;
}

function scaffoldContent(repoPath: string, oldM: any, v2: any) {
  const moduleSlug = deriveModuleSlug(v2.moduleId);
  const root = path.join(repoPath, 'manifest-content');
  const en   = path.join(root, 'en');

  // Make dirs
  for (const d of ['guide/slides', 'guide/videos', 'pages']) fs.mkdirSync(path.join(en, d), { recursive: true });

  const introPath = path.join(en, 'guide', 'intro.md');
  if (!fs.existsSync(introPath)) {
    const desc = oldM.description ?? oldM.purpose ?? `${v2.moduleId.replace(/-/g, ' ')} module.`;
    fs.writeFileSync(introPath, `# ${moduleSlug.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())}\n\n${desc}\n`);
  }

  const lifecycle = path.join(en, 'guide', 'lifecycle.json');
  if (!fs.existsSync(lifecycle)) {
    const phases = oldM.guide?.lifecycle?.phases;
    const fallback = [
      { name: 'Setup',  description: 'Module is installed and configured.' },
      { name: 'Active', description: 'Module is processing requests.' },
      { name: 'Retire', description: 'Module is decommissioned.' },
    ];
    fs.writeFileSync(lifecycle, JSON.stringify({ phases: Array.isArray(phases) ? phases : fallback }, null, 2) + '\n');
  }

  const resources = path.join(en, 'guide', 'resources.json');
  if (!fs.existsSync(resources)) {
    fs.writeFileSync(resources, JSON.stringify({
      links: [{ label: `${moduleSlug} OpenAPI`, href: `/api/${moduleSlug}/api/v1/G/openapi.json`, kind: 'api' }],
    }, null, 2) + '\n');
  }

  const pricing = path.join(en, 'guide', 'pricing.json');
  if (!fs.existsSync(pricing)) {
    fs.writeFileSync(pricing, JSON.stringify({
      tiers: [{ name: 'Bundled with platform', monthlyPrice: null, features: ['Included with every Zorbit deployment'] }],
    }, null, 2) + '\n');
  }

  const slidesIdx = path.join(en, 'guide', 'slides', 'index.json');
  if (!fs.existsSync(slidesIdx)) {
    fs.writeFileSync(slidesIdx, JSON.stringify({
      decks: { 'client-pitch': { label: 'Client pitch', audience: 'prospect', '$src': './client-pitch.json' } },
      default: 'client-pitch',
    }, null, 2) + '\n');
  }

  const slidesPitch = path.join(en, 'guide', 'slides', 'client-pitch.json');
  if (!fs.existsSync(slidesPitch)) {
    fs.writeFileSync(slidesPitch, JSON.stringify({
      deck: [
        {
          title: `${moduleSlug.replace(/_/g, ' ')} overview`,
          body:  oldM.description ?? `Overview of ${v2.moduleId}.`,
          narration: { audioSrc: './audio/client-pitch/0.mp3', text: oldM.description ?? `Overview of ${v2.moduleId}.`, duration: 10 },
        },
      ],
    }, null, 2) + '\n');
  }

  const videosIdx = path.join(en, 'guide', 'videos', 'index.json');
  if (!fs.existsSync(videosIdx)) {
    fs.writeFileSync(videosIdx, JSON.stringify({
      playlists: { 'demo-tour': { label: 'Demo tour', audience: 'prospect', '$src': './demo-tour.json' } },
      default: 'demo-tour',
    }, null, 2) + '\n');
  }

  const videosTour = path.join(en, 'guide', 'videos', 'demo-tour.json');
  if (!fs.existsSync(videosTour)) {
    fs.writeFileSync(videosTour, JSON.stringify({
      entries: [{ title: `${moduleSlug} demo`, src: `/static/videos/${moduleSlug}/demo.mp4`, playerType: 'tour', captions: `/static/videos/${moduleSlug}/demo.vtt`, duration: 60 }],
    }, null, 2) + '\n');
  }

  // pages — only generate stubs for ops items
  const opsSection = (v2.navigation.sections || []).find((s: any) => s.id === 'ops');
  for (const it of (opsSection?.items ?? [])) {
    const id = it.id;
    const f = path.join(en, 'pages', `${id}.json`);
    if (!fs.existsSync(f)) {
      fs.writeFileSync(f, JSON.stringify({
        pageId: `PG-${moduleSlug.toUpperCase().slice(0, 6)}-${id.toUpperCase().replace(/-/g, '').slice(0, 6)}`,
        dataSource: { beRoute: `/api/${moduleSlug}/api/v1/O/{org_id}/${id}`, scope: 'O', pageSize: 25 },
        columns: [
          { key: 'hashId',    label: 'ID',      type: 'id' },
          { key: 'name',      label: 'Name',    type: 'text', sortable: true, filterable: true },
          { key: 'createdAt', label: 'Created', type: 'datetime', format: 'relative', sortable: true },
        ],
        defaultSort: [{ field: 'createdAt', order: 'desc' }],
      }, null, 2) + '\n');
    }
  }

  // errors.json (top-level under manifest-content/, not in en/)
  const errorsPath = path.join(root, 'errors.json');
  if (!fs.existsSync(errorsPath)) {
    const prefix = moduleSlug.toUpperCase().slice(0, 6);
    fs.writeFileSync(errorsPath, JSON.stringify({
      [`${prefix}_NOT_FOUND`]:    { message: 'Resource not found.',         remedy: 'Check the ID.' },
      [`${prefix}_UNAUTHORIZED`]: { message: 'Insufficient privileges.',     remedy: 'Ask a super admin.' },
    }, null, 2) + '\n');
  }
}

// CLI
const args = process.argv.slice(2);
if (args.length < 1) { console.error('usage: migrate-to-v2.ts <repo-path> [--write]'); process.exit(2); }
const repoPath = path.resolve(args[0]);
const write    = args.includes('--write');

const oldPath = path.join(repoPath, 'zorbit-module-manifest.json');
if (!fs.existsSync(oldPath)) { console.error(`no manifest at ${oldPath}`); process.exit(2); }

const oldM   = readJson(oldPath);
const slugTrans = loadSlugTranslations();
const v2     = buildV2(oldM, slugTrans, repoPath);

if (write) {
  scaffoldContent(repoPath, oldM, v2);
  fs.writeFileSync(path.join(repoPath, 'zorbit-module-manifest.proposed.json'), JSON.stringify(v2, null, 2) + '\n');
  console.log(`wrote: ${repoPath}/zorbit-module-manifest.proposed.json`);
  console.log(`scaffolded: ${repoPath}/manifest-content/...`);
} else {
  console.log(JSON.stringify(v2, null, 2));
}
