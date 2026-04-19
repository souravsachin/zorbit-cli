import {
  buildManifestV2,
  buildCompositionManifest,
  VALID_SCAFFOLDS,
  VALID_CATEGORIES,
} from '../src/commands/zmb-manifest-v2';

// ---------------------------------------------------------------------------
// App scaffold — Business + Health Insurance edition
// ---------------------------------------------------------------------------

describe('buildManifestV2 — app scaffold with Business scaffold + Health Insurance edition', () => {
  const input = {
    slug: 'foo',
    name: 'Foo',
    moduleType: 'app' as const,
    description: 'Foo test module',
    scaffold: 'Business',
    edition: 'Health Insurance',
    category: 'Insurer',
    capability: 'Policy Administration',
  };

  const manifest = buildManifestV2(input);

  test('emits canonical top-level fields', () => {
    expect(manifest.moduleId).toBe('zorbit-app-foo');
    expect(manifest.moduleName).toBe('Foo');
    expect(manifest.moduleType).toBe('app');
    expect(manifest.version).toBe('1.0.0');
  });

  test('placement carries scaffold + scaffoldSortOrder', () => {
    const placement = manifest.placement as Record<string, unknown>;
    expect(placement.scaffold).toBe('Business');
    expect(placement.scaffoldSortOrder).toBe(30);
    expect(placement.capabilityArea).toBe('Policy Administration');
    expect(placement.sortOrder).toBe(10);
  });

  test('placement.edition populated for Business scaffold', () => {
    const placement = manifest.placement as Record<string, any>;
    expect(placement.edition).toBeDefined();
    expect(placement.edition.name).toBe('Health Insurance');
    expect(placement.edition.category).toBe('Insurer');
    expect(placement.businessLine).toBe('Distribution');
  });

  test('navigation.sections[0].items[0].feComponent = DashboardPage', () => {
    const navigation = manifest.navigation as any;
    expect(Array.isArray(navigation.sections)).toBe(true);
    expect(navigation.sections[0].items[0].feComponent).toBe('DashboardPage');
    expect(navigation.sections[0].items[0].feRoute).toBe('/m/foo/overview');
    expect(navigation.sections[0].items[0].beRoute).toBe('/api/foo/api/v1/G/health');
  });

  test('guide block present with all six subsections', () => {
    const guide = manifest.guide as any;
    expect(guide).toBeDefined();
    expect(guide.intro.feRoute).toBe('/m/foo/guide/intro');
    expect(guide.slides.feRoute).toBe('/m/foo/guide/presentation');
    expect(guide.lifecycle.feRoute).toBe('/m/foo/guide/lifecycle');
    expect(guide.videos.feRoute).toBe('/m/foo/guide/videos');
    expect(guide.docs.feRoute).toBe('/m/foo/guide/resources');
    expect(guide.pricing.feRoute).toBe('/m/foo/guide/pricing');
  });

  test('deployments block has health + build + environments', () => {
    const dep = manifest.deployments as any;
    expect(dep.health.beRoute).toBe('/api/foo/api/v1/G/health');
    expect(dep.build.nodeVersion).toBe(process.versions.node);
    expect(Array.isArray(dep.environments)).toBe(true);
    expect(dep.environments.length).toBeGreaterThan(0);
  });

  test('db block declares six operations', () => {
    const db = manifest.db as any;
    expect(db).toBeDefined();
    expect(db.operations.seedSystemMin.beRoute).toBe('/api/foo/api/v1/G/seed/system-min');
    expect(db.operations.seedDemoData).toBeDefined();
    expect(db.operations.flushDemoData).toBeDefined();
    expect(db.operations.flushAllData.destructive).toBe(true);
    expect(db.operations.backup).toBeDefined();
    expect(db.operations.restore.destructive).toBe(true);
  });

  test('manifest is valid JSON', () => {
    const json = JSON.stringify(manifest);
    expect(() => JSON.parse(json)).not.toThrow();
  });
});

// ---------------------------------------------------------------------------
// App scaffold — Platform Core
// ---------------------------------------------------------------------------

describe('buildManifestV2 — app scaffold with Platform Core (for new cor module)', () => {
  const input = {
    slug: 'my-registry',
    name: 'My Registry',
    moduleType: 'cor' as const,
    description: 'Platform core module',
    scaffold: 'Platform Core',
    capability: 'Module Registry',
  };

  const manifest = buildManifestV2(input);

  test('moduleType=cor reflected in moduleId', () => {
    expect(manifest.moduleId).toBe('zorbit-cor-my_registry');
    expect(manifest.moduleType).toBe('cor');
  });

  test('placement.scaffold = Platform Core, no edition block', () => {
    const placement = manifest.placement as any;
    expect(placement.scaffold).toBe('Platform Core');
    expect(placement.scaffoldSortOrder).toBe(10);
    expect(placement.edition).toBeUndefined();
    expect(placement.businessLine).toBeUndefined();
  });

  test('feComponent default still DashboardPage', () => {
    const navigation = manifest.navigation as any;
    expect(navigation.sections[0].items[0].feComponent).toBe('DashboardPage');
  });

  test('deployments + db blocks included', () => {
    expect(manifest.deployments).toBeDefined();
    expect(manifest.db).toBeDefined();
  });

  test('Business-only validation does not trigger for Platform Core', () => {
    expect(() => buildManifestV2(input)).not.toThrow();
  });
});

// ---------------------------------------------------------------------------
// Composition-only scaffold with 2 resources
// ---------------------------------------------------------------------------

describe('buildCompositionManifest — composition-only with 2 resources', () => {
  const input = {
    slug: 'bar',
    name: 'Bar',
    description: 'Bar composition test',
    scaffold: 'Business',
    edition: 'Health Insurance',
    category: 'Insurer',
    capability: 'Rate Management',
    whitelabelId: 'WL-TEST1',
    resources: ['rate-cards', 'test-data'],
  };

  const manifest = buildCompositionManifest(input);

  test('moduleType=app, moduleId uses slug', () => {
    expect(manifest.moduleId).toBe('zorbit-app-bar');
    expect(manifest.moduleType).toBe('app');
  });

  test('composition.cosmetics.whitelabel.id set from input', () => {
    const comp = manifest.composition as any;
    expect(comp.cosmetics.whitelabel.id).toBe('WL-TEST1');
  });

  test('composition.resources["rate-cards"].new is present with formBuilder.templateId', () => {
    const comp = manifest.composition as any;
    expect(comp.resources['rate-cards']).toBeDefined();
    expect(comp.resources['rate-cards'].new).toBeDefined();
    expect(comp.resources['rate-cards'].new.formBuilder.templateId).toMatch(/^FRM-/);
  });

  test('composition.resources["rate-cards"].list has datatable page + export actions', () => {
    const comp = manifest.composition as any;
    expect(comp.resources['rate-cards'].list.datatable.pageId).toMatch(/^DT-/);
    expect(comp.resources['rate-cards'].list.datatable.actions.export.csv).toBe(true);
  });

  test('composition.resources["test-data"].details has datatable page', () => {
    const comp = manifest.composition as any;
    expect(comp.resources['test-data']).toBeDefined();
    expect(comp.resources['test-data'].details.datatable.pageId).toMatch(/^DT-/);
  });

  test('navigation items use feComponent=CompositionRenderer', () => {
    const navigation = manifest.navigation as any;
    const items = navigation.sections[0].items as any[];
    items.forEach((i) => expect(i.feComponent).toBe('CompositionRenderer'));
  });

  test('db block absent (composition ships no backend)', () => {
    expect(manifest.db).toBeUndefined();
  });

  test('guide block still present for composition modules', () => {
    expect(manifest.guide).toBeDefined();
  });

  test('manifest is valid JSON', () => {
    const json = JSON.stringify(manifest);
    expect(() => JSON.parse(json)).not.toThrow();
  });
});

// ---------------------------------------------------------------------------
// Validation failures
// ---------------------------------------------------------------------------

describe('validation errors', () => {
  test('rejects unknown scaffold', () => {
    expect(() =>
      buildManifestV2({
        slug: 'x',
        name: 'X',
        moduleType: 'app',
        description: '',
        scaffold: 'NotAScaffold',
        capability: 'c',
      }),
    ).toThrow(/scaffold/);
  });

  test('rejects Business without edition', () => {
    expect(() =>
      buildManifestV2({
        slug: 'x',
        name: 'X',
        moduleType: 'app',
        description: '',
        scaffold: 'Business',
        category: 'Insurer',
        capability: 'c',
      }),
    ).toThrow(/edition/);
  });

  test('rejects Business without category', () => {
    expect(() =>
      buildManifestV2({
        slug: 'x',
        name: 'X',
        moduleType: 'app',
        description: '',
        scaffold: 'Business',
        edition: 'Health Insurance',
        capability: 'c',
      }),
    ).toThrow(/category/);
  });

  test('rejects unknown category', () => {
    expect(() =>
      buildManifestV2({
        slug: 'x',
        name: 'X',
        moduleType: 'app',
        description: '',
        scaffold: 'Business',
        edition: 'Health Insurance',
        category: 'NotACategory',
        capability: 'c',
      }),
    ).toThrow(/category/);
  });

  test('composition rejects empty resources', () => {
    expect(() =>
      buildCompositionManifest({
        slug: 'x',
        name: 'X',
        description: '',
        scaffold: 'Business',
        edition: 'Health Insurance',
        category: 'Insurer',
        capability: 'c',
        whitelabelId: 'WL-XX01',
        resources: [],
      }),
    ).toThrow(/resource/);
  });

  test('composition rejects missing whitelabel', () => {
    expect(() =>
      buildCompositionManifest({
        slug: 'x',
        name: 'X',
        description: '',
        scaffold: 'Business',
        edition: 'Health Insurance',
        category: 'Insurer',
        capability: 'c',
        whitelabelId: '',
        resources: ['a'],
      }),
    ).toThrow(/whitelabel/i);
  });
});

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

describe('constants', () => {
  test('VALID_SCAFFOLDS matches plan', () => {
    expect(VALID_SCAFFOLDS).toContain('Platform Core');
    expect(VALID_SCAFFOLDS).toContain('Platform Feature Services');
    expect(VALID_SCAFFOLDS).toContain('Business');
    expect(VALID_SCAFFOLDS).toContain('AI and Voice');
    expect(VALID_SCAFFOLDS).toContain('Administration');
  });

  test('VALID_CATEGORIES matches plan', () => {
    expect(VALID_CATEGORIES).toEqual(['Insurer', 'UHC', 'TPA', 'Broker', 'Provider', 'Regulator']);
  });
});
