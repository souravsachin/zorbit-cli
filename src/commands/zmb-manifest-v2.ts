// ---------------------------------------------------------------------------
// zmb-manifest-v2.ts
// ---------------------------------------------------------------------------
// Pure builder functions that emit manifest v2-compliant JSON for the zmb
// factory. The templates were replaced by programmatic builders so the
// generated shape always matches PLAN-manifest-v2-extensions.md without
// risk of drift between Handlebars escaping + JSON validity.
//
// Two public builders:
//   - buildManifestV2(input)       — for --type=app (full scaffold)
//   - buildCompositionManifest(i)  — for --type=composition (manifest only)
//
// Both return plain JS objects. Caller is responsible for JSON.stringify.
// ---------------------------------------------------------------------------

export const VALID_SCAFFOLDS = [
  'Platform Core',
  'Platform Feature Services',
  'Business',
  'AI and Voice',
  'Administration',
] as const;

export const VALID_CATEGORIES = [
  'Insurer',
  'UHC',
  'TPA',
  'Broker',
  'Provider',
  'Regulator',
] as const;

export type Scaffold = typeof VALID_SCAFFOLDS[number];
export type Category = typeof VALID_CATEGORIES[number];

export interface ManifestBuildInput {
  slug: string;
  name: string;
  moduleType: 'app' | 'cor' | 'pfs' | 'tpm' | 'sdk' | 'ext';
  description: string;
  scaffold: string;
  edition?: string;
  category?: string;
  capability: string;
  /** When true, include seedSystemMin/seedDemoData/... db endpoints as TODOs. Default true for app/cor/pfs. */
  includeDb?: boolean;
}

export interface CompositionBuildInput {
  slug: string;
  name: string;
  description: string;
  scaffold: string;
  edition?: string;
  category?: string;
  capability: string;
  whitelabelId: string;
  resources: string[];
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const DEFAULT_SCAFFOLD_SORT_ORDER: Record<string, number> = {
  'Platform Core': 10,
  'Platform Feature Services': 20,
  'Business': 30,
  'AI and Voice': 40,
  'Administration': 50,
};

function capitalize(str: string): string {
  return str.charAt(0).toUpperCase() + str.slice(1);
}

function toPascal(slugOrName: string): string {
  return slugOrName
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((w) => capitalize(w.toLowerCase()))
    .join('');
}

function apiPrefix(slug: string): string {
  // Used in beRoutes. Hyphens allowed in URL paths.
  return `/api/${slug}/api/v1`;
}

// ---------------------------------------------------------------------------
// Placement builder
// ---------------------------------------------------------------------------

function buildPlacement(input: {
  scaffold: string;
  edition?: string;
  category?: string;
  capability: string;
}): Record<string, unknown> {
  const scaffoldSortOrder =
    DEFAULT_SCAFFOLD_SORT_ORDER[input.scaffold] ?? 30;

  const placement: Record<string, unknown> = {
    scaffold: input.scaffold,
    scaffoldSortOrder,
    capabilityArea: input.capability,
    sortOrder: 10,
  };

  if (input.scaffold === 'Business') {
    placement.edition = {
      name: input.edition || 'Unspecified Edition',
      category: input.category || 'Insurer',
      categorySortOrder: 10,
      sortOrder: 10,
      icon: 'Heart',
      iconBg: '#dcfce7',
      iconColor: '#15803d',
      iconRing: '#86efac',
    };
    placement.businessLine = 'Distribution';
  }

  return placement;
}

// ---------------------------------------------------------------------------
// Guide placeholder
// ---------------------------------------------------------------------------

function buildGuide(slug: string, name: string): Record<string, unknown> {
  return {
    intro: {
      headline: `${name} — placeholder headline`,
      summary: `Replace this one-paragraph pitch describing what ${name} does.`,
      feRoute: `/m/${slug}/guide/intro`,
    },
    slides: {
      feRoute: `/m/${slug}/guide/presentation`,
      deck: [
        { title: 'Problem', body: 'Placeholder — describe the problem this module solves.' },
        { title: 'Solution', body: 'Placeholder — describe the solution.' },
        { title: 'Architecture', body: 'Placeholder — describe the architecture.' },
      ],
    },
    lifecycle: {
      feRoute: `/m/${slug}/guide/lifecycle`,
      phases: [
        { name: 'Draft', description: 'Author a new record.' },
        { name: 'Review', description: 'Peer review.' },
        { name: 'Published', description: 'Live / in use.' },
        { name: 'Retired', description: 'Archived; read-only.' },
      ],
    },
    videos: {
      feRoute: `/m/${slug}/guide/videos`,
      entries: [
        {
          title: 'Quick start (placeholder)',
          duration: 0,
          playerType: 'chapter-list',
          // MX-2094 validator requires src to be non-empty. Use a
          // TODO-style URL pointing at the module's own /m route so the
          // author sees where to replace it.
          src: `/m/${slug}/guide/videos/TODO-quick-start.mp4`,
          poster: '',
          chapters: [],
        },
      ],
    },
    docs: {
      feRoute: `/m/${slug}/guide/resources`,
      links: [
        { label: 'REST API reference', href: `${apiPrefix(slug)}/api-docs` },
      ],
    },
    pricing: {
      feRoute: `/m/${slug}/guide/pricing`,
      tiers: [
        { name: 'Community', monthlyPrice: 0, features: ['Coming soon'] },
        { name: 'Business', monthlyPrice: null, features: ['Coming soon'] },
        { name: 'Enterprise', monthlyPrice: null, features: ['Coming soon'] },
      ],
    },
  };
}

// ---------------------------------------------------------------------------
// Deployments placeholder
// ---------------------------------------------------------------------------

function buildDeployments(slug: string, moduleType: string): Record<string, unknown> {
  return {
    health: {
      beRoute: `${apiPrefix(slug)}/G/health`,
    },
    build: {
      commitSha: 'placeholder-commit-sha',
      builtAt: new Date().toISOString(),
      nodeVersion: process.versions.node,
      dockerImage: `zorbit-${moduleType}-${slug}:1.0.0`,
    },
    environments: [
      { name: 'uat', url: 'https://zorbit-uat.onezippy.ai', status: 'unknown' },
    ],
    runbook: { href: `/m/${slug}/deployments/runbook` },
  };
}

// ---------------------------------------------------------------------------
// DB section placeholder
// ---------------------------------------------------------------------------

function buildDb(slug: string, dbName: string): Record<string, unknown> {
  const privPrefix = slug.replace(/-/g, '_');
  return {
    dbType: 'postgres',
    dbName,
    operations: {
      seedSystemMin: {
        beRoute: `${apiPrefix(slug)}/G/seed/system-min`,
        method: 'POST',
        privilege: `${privPrefix}.seed.system-min`,
      },
      seedDemoData: {
        beRoute: `${apiPrefix(slug)}/G/seed/demo`,
        method: 'POST',
        privilege: `${privPrefix}.seed.demo`,
      },
      flushDemoData: {
        beRoute: `${apiPrefix(slug)}/G/seed/demo`,
        method: 'DELETE',
        privilege: `${privPrefix}.seed.demo`,
      },
      flushAllData: {
        beRoute: `${apiPrefix(slug)}/G/seed/all`,
        method: 'DELETE',
        privilege: `${privPrefix}.seed.all`,
        destructive: true,
      },
      backup: {
        beRoute: `${apiPrefix(slug)}/G/db/backup`,
        method: 'POST',
        privilege: `${privPrefix}.db.backup`,
      },
      restore: {
        beRoute: `${apiPrefix(slug)}/G/db/restore`,
        method: 'POST',
        privilege: `${privPrefix}.db.restore`,
        destructive: true,
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Navigation placeholder (one section, one item, carries feComponent)
// ---------------------------------------------------------------------------

function buildNavigation(
  slug: string,
  name: string,
  capability: string,
): Record<string, unknown> {
  const privPrefix = slug.replace(/-/g, '_');
  return {
    sections: [
      {
        label: capability || name,
        icon: 'dashboard',
        sortOrder: 10,
        privilege: `${privPrefix}.view`,
        items: [
          {
            label: 'Overview',
            feRoute: `/m/${slug}/overview`,
            beRoute: `${apiPrefix(slug)}/G/health`,
            feComponent: 'DashboardPage',
            privilege: `${privPrefix}.overview`,
            sortOrder: 1,
            icon: 'info',
          },
        ],
      },
    ],
  };
}

// ---------------------------------------------------------------------------
// App manifest builder
// ---------------------------------------------------------------------------

export function buildManifestV2(input: ManifestBuildInput): Record<string, unknown> {
  // Validate inputs
  if (!input.slug) throw new Error('slug is required');
  if (!input.name) throw new Error('name is required');
  if (!input.capability) throw new Error('capability is required');
  if (!VALID_SCAFFOLDS.includes(input.scaffold as Scaffold)) {
    throw new Error(
      `Invalid scaffold "${input.scaffold}". Must be one of ${VALID_SCAFFOLDS.join(', ')}`,
    );
  }
  if (input.scaffold === 'Business') {
    if (!input.edition) throw new Error('edition is required when scaffold=Business');
    if (!input.category) throw new Error('category is required when scaffold=Business');
    if (!VALID_CATEGORIES.includes(input.category as Category)) {
      throw new Error(
        `Invalid category "${input.category}". Must be one of ${VALID_CATEGORIES.join(', ')}`,
      );
    }
  }

  const moduleType = input.moduleType || 'app';
  const moduleId = `zorbit-${moduleType}-${input.slug.replace(/-/g, '_')}`;
  const dbName = `zorbit_${input.slug.replace(/-/g, '_')}`;

  const includeDb = input.includeDb !== false;

  const manifest: Record<string, unknown> = {
    moduleId,
    moduleName: input.name,
    moduleType,
    version: '1.0.0',
    description: input.description || `${input.name} module`,
    owner: 'OneZippy.ai',
    icon: 'dashboard',
    color: '#4f46e5',

    placement: buildPlacement({
      scaffold: input.scaffold,
      edition: input.edition,
      category: input.category,
      capability: input.capability,
    }),

    registration: {
      kafkaTopic: 'platform-module-announcements',
      manifestUrl: `https://zorbit-uat.onezippy.ai${apiPrefix(input.slug)}/G/manifest`,
    },

    navigation: buildNavigation(input.slug, input.name, input.capability),

    guide: buildGuide(input.slug, input.name),

    deployments: buildDeployments(input.slug, moduleType),
  };

  if (includeDb) {
    manifest.db = buildDb(input.slug, dbName);
  }

  return manifest;
}

// ---------------------------------------------------------------------------
// Composition manifest builder
// ---------------------------------------------------------------------------

function placeholderId(prefix: string, idx: number, subkey: string): string {
  // Deterministic placeholder IDs so tests can match.
  const hash = `${idx.toString(16).toUpperCase().padStart(2, '0')}${subkey
    .charAt(0)
    .toUpperCase()}${subkey.charAt(1)?.toUpperCase() ?? 'X'}`;
  return `${prefix}-${hash}`.slice(0, 9);
}

function buildResourceEntry(resourceName: string, idx: number): Record<string, unknown> {
  return {
    new: {
      formBuilder: {
        templateId: placeholderId('FRM', idx, 'new'),
      },
    },
    list: {
      datatable: {
        pageId: placeholderId('DT', idx, 'li'),
        fields: [],
        sortBy: [],
        lookups: {},
        actions: { export: { csv: true, pdf: false } },
      },
    },
    details: {
      datatable: {
        pageId: placeholderId('DT', idx, 'dt'),
        actions: { export: { pdf: true } },
      },
    },
  };
}

export function buildCompositionManifest(
  input: CompositionBuildInput,
): Record<string, unknown> {
  if (!input.slug) throw new Error('slug is required');
  if (!input.name) throw new Error('name is required');
  if (!input.whitelabelId) throw new Error('whitelabelId is required');
  if (!input.resources || input.resources.length === 0) {
    throw new Error('at least one resource is required');
  }
  if (!VALID_SCAFFOLDS.includes(input.scaffold as Scaffold)) {
    throw new Error(
      `Invalid scaffold "${input.scaffold}". Must be one of ${VALID_SCAFFOLDS.join(', ')}`,
    );
  }

  const moduleId = `zorbit-app-${input.slug.replace(/-/g, '_')}`;

  const resourcesMap: Record<string, unknown> = {};
  input.resources.forEach((r, idx) => {
    resourcesMap[r] = buildResourceEntry(r, idx);
  });

  // Composition modules don't ship backend. We still emit placement,
  // navigation, guide blocks so the console has somewhere to route. We
  // deliberately OMIT the `db` block (no DB) and the `deployments.health`
  // beRoute (no backend to healthcheck).
  const manifest: Record<string, unknown> = {
    moduleId,
    moduleName: input.name,
    moduleType: 'app',
    version: '1.0.0',
    description: input.description || `${input.name} composition-only module`,
    owner: 'OneZippy.ai',
    icon: 'dashboard',
    color: '#4f46e5',

    placement: buildPlacement({
      scaffold: input.scaffold,
      edition: input.edition,
      category: input.category,
      capability: input.capability,
    }),

    registration: {
      kafkaTopic: 'platform-module-announcements',
      manifestUrl: `https://zorbit-uat.onezippy.ai${apiPrefix(input.slug)}/G/manifest`,
    },

    navigation: {
      sections: [
        {
          label: input.capability || input.name,
          icon: 'dashboard',
          sortOrder: 10,
          privilege: `${input.slug.replace(/-/g, '_')}.view`,
          items: input.resources.flatMap((r) => [
            {
              label: `${toPascal(r)} — List`,
              feRoute: `/m/${input.slug}/${r}/list`,
              feComponent: 'CompositionRenderer',
              privilege: `${input.slug.replace(/-/g, '_')}.${r.replace(/-/g, '_')}.read`,
              sortOrder: 1,
              icon: 'list',
            },
            {
              label: `${toPascal(r)} — New`,
              feRoute: `/m/${input.slug}/${r}/new`,
              feComponent: 'CompositionRenderer',
              privilege: `${input.slug.replace(/-/g, '_')}.${r.replace(/-/g, '_')}.create`,
              sortOrder: 2,
              icon: 'add',
            },
          ]),
        },
      ],
    },

    guide: buildGuide(input.slug, input.name),

    deployments: {
      // Composition modules have no backend of their own. MX-2094
      // validator still requires a non-empty health.beRoute, so we
      // point at the module-registry health endpoint — a composition
      // module is "alive" as long as the registry can serve its manifest.
      health: { beRoute: '/api/module_registry/api/v1/G/health' },
      build: {
        commitSha: 'placeholder-commit-sha',
        builtAt: new Date().toISOString(),
        nodeVersion: process.versions.node,
        dockerImage: null,
      },
      environments: [
        { name: 'uat', url: 'https://zorbit-uat.onezippy.ai', status: 'n/a' },
      ],
      runbook: { href: `/m/${input.slug}/deployments/runbook` },
    },

    composition: {
      cosmetics: {
        whitelabel: { id: input.whitelabelId },
      },
      resources: resourcesMap,
    },
  };

  return manifest;
}
