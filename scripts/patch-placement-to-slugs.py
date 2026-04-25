#!/usr/bin/env python3
"""
patch-placement-to-slugs.py — Stamps SLUG-only placement into every module manifest.

Per owner directive 2026-04-25: manifests carry SLUGS, never labels. Display labels
come from slug-translations.json (or fallback = slug). Renaming a label = edit one
JSON line in slug-translations.json, never re-register modules.

This script:
1. Reads slug-translations.json -> moduleAlias section
2. For every row in zorbit_module_registry.modules + zorbit_navigation.registered_modules,
   sets manifest.placement.{scaffold, businessLine, capabilityArea} = the slug values
   from moduleAlias, removing any pre-existing label-style values.
3. Restarts the navigation service.

Usage:
  python3 patch-placement-to-slugs.py --translations /etc/zorbit/slug-translations.json --env-prefix ze
"""
import json, subprocess, sys, os, argparse

ap = argparse.ArgumentParser()
ap.add_argument('--translations', default='/etc/zorbit/slug-translations.json')
ap.add_argument('--env-prefix', default='ze')
ap.add_argument('--dry-run', action='store_true')
args = ap.parse_args()

if not os.path.exists(args.translations):
    print(f'ERROR: translations file not found: {args.translations}', file=sys.stderr)
    sys.exit(2)

T = json.load(open(args.translations))
ALIAS = T.get('moduleAlias', {})
SCAFFOLD_SLUGS = set(T.get('scaffold', {}).keys())
BL_SLUGS = set(k for k in T.get('businessLine', {}).keys() if not k.startswith('_'))
CA_SLUGS = set(k for k in T.get('capabilityArea', {}).keys() if not k.startswith('_'))


def psql(db, sql):
    cmd = ['docker', 'exec', 'zs-pg', 'psql', '-U', 'zorbit', '-d', db, '-tAF\t', '-c', sql]
    out = subprocess.check_output(cmd, text=True)
    return out


def slug_for(module_id, current_placement):
    """Decide the slug placement for a module."""
    alias = ALIAS.get(module_id)
    if alias:
        return {
            'scaffold': alias.get('scaffold'),
            'businessLine': alias.get('businessLine'),
            'capabilityArea': alias.get('capabilityArea'),
        }
    # Fallback: try to coerce existing values to slugs by lowercasing + replacing space
    sc = (current_placement or {}).get('scaffold') or ''
    sc_slug = sc.lower().replace(' ', '_').replace('&', 'and') if sc else None
    if sc_slug and sc_slug in SCAFFOLD_SLUGS:
        return {'scaffold': sc_slug, 'businessLine': None, 'capabilityArea': None}
    return None


def patch_db(db, table, key_col):
    print(f'\n=== {db}.{table} ===')
    col = 'manifest_data' if table == 'modules' else 'manifest'
    rows = psql(db, f"SELECT {key_col}, COALESCE({col}, '{{}}'::jsonb)::text FROM {table} ORDER BY {key_col}")
    fixed = 0
    skipped = []
    for line in rows.strip().split('\n'):
        if not line.strip():
            continue
        parts = line.split('\t', 1)
        if len(parts) != 2:
            continue
        mod_id, manifest_str = parts
        try:
            manifest = json.loads(manifest_str) if manifest_str.strip() else {}
        except Exception as e:
            skipped.append((mod_id, f'json: {e}'))
            continue
        cur_pl = manifest.get('placement', {})
        new_pl = slug_for(mod_id, cur_pl)
        if not new_pl or not new_pl.get('scaffold'):
            skipped.append((mod_id, 'no alias entry, no slug-coercion match'))
            continue
        # Build the canonical slug placement
        out_pl = {'scaffold': new_pl['scaffold']}
        if new_pl['scaffold'] == 'business':
            if not new_pl.get('businessLine'):
                skipped.append((mod_id, 'business scaffold but no businessLine slug'))
                continue
            out_pl['businessLine'] = new_pl['businessLine']
            if new_pl.get('capabilityArea'):
                out_pl['capabilityArea'] = new_pl['capabilityArea']
        # Preserve other placement fields not under our control (sortOrder, edition)
        for k, v in cur_pl.items():
            if k not in ('scaffold', 'businessLine', 'capabilityArea'):
                out_pl[k] = v
        if out_pl == cur_pl:
            continue
        manifest['placement'] = out_pl
        json_lit = json.dumps(manifest).replace("'", "''")
        if not args.dry_run:
            psql(db, f"UPDATE {table} SET {col} = '{json_lit}'::jsonb WHERE {key_col} = '{mod_id}'")
        fixed += 1
        print(f'  FIX {mod_id}: → {out_pl}')
    print(f'  fixed={fixed} skipped={len(skipped)}')
    for m, why in skipped:
        print(f'    - {m}: {why}')
    return fixed, skipped


total_fixed = 0
all_skipped = []
for db, table, key in [
    ('zorbit_module_registry', 'modules', 'module_id'),
    ('zorbit_navigation', 'registered_modules', 'module_id'),
]:
    f, s = patch_db(db, table, key)
    total_fixed += f
    all_skipped.extend((db, m, why) for m, why in s)

if not args.dry_run:
    print('\nRestarting navigation service...')
    subprocess.run(['docker', 'exec', f'{args.env_prefix}-core', 'pm2', 'restart', 'zorbit-navigation'], capture_output=True)

print(f'\nTOTAL FIXES: {total_fixed}')
if all_skipped:
    print(f'SKIPPED: {len(all_skipped)}')
    for db, m, why in all_skipped:
        print(f'  {db}.{m}: {why}')
sys.exit(0)
