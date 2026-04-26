import * as fs from 'fs-extra';
import * as os from 'os';
import * as path from 'path';
import { __test__ } from '../src/commands/env-install';

const { resolveInstallPlan, normaliseSlug } = __test__;

// Build a minimal in-memory spec mirroring the v1 schema, so the test does
// not depend on an on-disk install-presets.json.
function makeSpec() {
  return {
    version: '1.0.0',
    spec_owner: 'test',
    updated: '2026-04-27',
    groups: {
      core: {
        label: 'Core',
        description: 'core platform',
        always_required: true,
        modules: ['zorbit-identity', 'zorbit-authorization', 'zorbit-navigation'],
      },
      shared_infra: {
        label: 'Shared Infra',
        description: 'infra',
        always_required: true,
        modules: ['zs-pg', 'zs-kafka'],
      },
      pfs: {
        label: 'PFS',
        description: 'platform feature services',
        modules: ['zorbit-pfs-rtc', 'zorbit-pfs-chat'],
      },
      apps: {
        label: 'Apps',
        description: 'business apps',
        modules: ['zorbit-app-broker'],
        planned_modules: ['zorbit-app-not_yet_published'],
      },
    },
    presets: {
      minimal: {
        label: 'Minimal',
        description: 'just core',
        estimated_services: 5,
        estimated_memory_gb: 4,
        estimated_disk_gb: 12,
        includes_groups: [],
      },
      recommended: {
        label: 'Recommended',
        description: 'core+pfs',
        estimated_services: 7,
        estimated_memory_gb: 7,
        estimated_disk_gb: 22,
        includes_groups: ['pfs'],
      },
      max: {
        label: 'Max',
        description: 'all groups',
        estimated_services: 10,
        estimated_memory_gb: 12,
        estimated_disk_gb: 50,
        includes_all_groups: true,
      },
    },
  };
}

const MANIFEST = new Set([
  'zorbit-identity',
  'zorbit-authorization',
  'zorbit-navigation',
  'zs-pg',
  'zs-kafka',
  'zorbit-pfs-rtc',
  'zorbit-pfs-chat',
  'zorbit-app-broker',
  'zorbit-app-jayna',
]);

describe('env install resolver', () => {
  describe('preset resolution', () => {
    it('minimal preset includes only always_required groups', () => {
      const plan = resolveInstallPlan({
        env: 'qa',
        preset: 'minimal',
        add: [],
        remove: [],
        spec: makeSpec(),
        manifestNames: MANIFEST,
      });
      // 3 core + 2 shared_infra = 5
      expect(plan.modules.sort()).toEqual([
        'zorbit-authorization',
        'zorbit-identity',
        'zorbit-navigation',
        'zs-kafka',
        'zs-pg',
      ]);
    });

    it('recommended preset adds pfs group', () => {
      const plan = resolveInstallPlan({
        env: 'qa',
        preset: 'recommended',
        add: [],
        remove: [],
        spec: makeSpec(),
        manifestNames: MANIFEST,
      });
      expect(plan.modules).toContain('zorbit-pfs-rtc');
      expect(plan.modules).toContain('zorbit-pfs-chat');
      expect(plan.modules).toContain('zorbit-identity'); // always required
      expect(plan.modules).toHaveLength(7);
    });

    it('max preset includes every group', () => {
      const plan = resolveInstallPlan({
        env: 'qa',
        preset: 'max',
        add: [],
        remove: [],
        spec: makeSpec(),
        manifestNames: MANIFEST,
      });
      expect(plan.modules).toContain('zorbit-app-broker');
      // planned_modules are skipped, not installed
      expect(plan.modules).not.toContain('zorbit-app-not_yet_published');
      expect(plan.skipped_planned).toContain('zorbit-app-not_yet_published');
    });
  });

  describe('--add overrides', () => {
    it('adds canonical slug to minimal', () => {
      const plan = resolveInstallPlan({
        env: 'qa',
        preset: 'minimal',
        add: ['zorbit-app-jayna'],
        remove: [],
        spec: makeSpec(),
        manifestNames: MANIFEST,
      });
      expect(plan.modules).toContain('zorbit-app-jayna');
      expect(plan.added).toEqual(['zorbit-app-jayna']);
    });

    it('normalises short slugs (jayna -> zorbit-app-jayna)', () => {
      const plan = resolveInstallPlan({
        env: 'qa',
        preset: 'minimal',
        add: ['jayna'],
        remove: [],
        spec: makeSpec(),
        manifestNames: MANIFEST,
      });
      expect(plan.modules).toContain('zorbit-app-jayna');
      expect(plan.added).toEqual(['zorbit-app-jayna']);
    });

    it('rejects unknown slugs in --add', () => {
      expect(() =>
        resolveInstallPlan({
          env: 'qa',
          preset: 'minimal',
          add: ['nonexistent-module'],
          remove: [],
          spec: makeSpec(),
          manifestNames: MANIFEST,
        }),
      ).toThrow(/does not resolve to any module/);
    });
  });

  describe('--remove overrides', () => {
    it('removes a module from max', () => {
      const plan = resolveInstallPlan({
        env: 'qa',
        preset: 'max',
        add: [],
        remove: ['zorbit-pfs-chat'],
        spec: makeSpec(),
        manifestNames: MANIFEST,
      });
      expect(plan.modules).not.toContain('zorbit-pfs-chat');
      expect(plan.removed).toEqual(['zorbit-pfs-chat']);
    });

    it('warns but does not throw if --remove target absent', () => {
      const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
      const plan = resolveInstallPlan({
        env: 'qa',
        preset: 'minimal',
        add: [],
        remove: ['zorbit-pfs-chat'], // not in minimal
        spec: makeSpec(),
        manifestNames: MANIFEST,
      });
      expect(plan.removed).toEqual([]);
      warn.mockRestore();
    });
  });

  describe('lockfile integrity', () => {
    it('preserves env, preset, version, and resolver fields', () => {
      const plan = resolveInstallPlan({
        env: 'demo',
        preset: 'recommended',
        add: ['jayna'],
        remove: ['zorbit-pfs-chat'],
        spec: makeSpec(),
        manifestNames: MANIFEST,
      });
      expect(plan.env).toBe('demo');
      expect(plan.preset).toBe('recommended');
      expect(plan.source_spec_version).toBe('1.0.0');
      expect(plan.resolver_version).toBe('1.0.0');
      expect(plan.resolved_at).toMatch(/\d{4}-\d{2}-\d{2}T/);
    });

    it('lockfile is valid JSON when written', () => {
      const tmp = path.join(os.tmpdir(), `zorbit-test-lockfile-${Date.now()}.json`);
      const plan = resolveInstallPlan({
        env: 'qa',
        preset: 'minimal',
        add: [],
        remove: [],
        spec: makeSpec(),
        manifestNames: MANIFEST,
      });
      fs.writeFileSync(tmp, JSON.stringify(plan, null, 2));
      const reparsed = JSON.parse(fs.readFileSync(tmp, 'utf-8'));
      expect(reparsed.env).toBe('qa');
      expect(reparsed.modules).toEqual(plan.modules);
      fs.removeSync(tmp);
    });
  });

  describe('slug normalisation', () => {
    it.each([
      ['rtc', 'zorbit-pfs-rtc'],
      ['pfs-rtc', 'zorbit-pfs-rtc'],
      ['zorbit-pfs-rtc', 'zorbit-pfs-rtc'],
      ['identity', 'zorbit-identity'],
      ['jayna', 'zorbit-app-jayna'],
    ])('"%s" resolves to "%s"', (input, expected) => {
      expect(normaliseSlug(input, MANIFEST)).toBe(expected);
    });

    it('returns null for unknown slug', () => {
      expect(normaliseSlug('nope', MANIFEST)).toBeNull();
    });
  });

  describe('always-required groups', () => {
    it('always-required groups merge in even when not in includes_groups', () => {
      const plan = resolveInstallPlan({
        env: 'qa',
        preset: 'minimal', // includes_groups: []
        add: [],
        remove: [],
        spec: makeSpec(),
        manifestNames: MANIFEST,
      });
      // shared_infra is always_required
      expect(plan.modules).toContain('zs-pg');
      expect(plan.modules).toContain('zs-kafka');
    });
  });

  describe('unknown preset', () => {
    it('throws with helpful message', () => {
      expect(() =>
        resolveInstallPlan({
          env: 'qa',
          preset: 'bogus',
          add: [],
          remove: [],
          spec: makeSpec(),
          manifestNames: MANIFEST,
        }),
      ).toThrow(/Unknown preset "bogus"/);
    });
  });
});
