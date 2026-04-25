#!/usr/bin/env python3
"""
patch-placement-to-canonical.py — Idempotent placement-vocab normaliser.

Reads enum-placement-canonical.json, walks every row in
zorbit_module_registry.modules + zorbit_navigation.registered_modules,
rewrites each manifest's placement.scaffold / .businessLine / .capabilityArea
to canonical values per the enum. Then restarts zorbit-navigation so it
rehydrates with the corrected placement.

Used in two places:
  1. Manually right now to fix the live deploy.
  2. Wired into post-deploy-bootstrap.sh after manifest-fetch step.

Run this script ON the VM that hosts the bundle containers (VM 110 in the
current dev env). It assumes:
  - docker exec zs-pg psql ... reaches Postgres
  - docker exec ze-core pm2 ... reaches the navigation service container
  - The enum file has been copied to /etc/zorbit/<env>/enum-placement-canonical.json

Exit code 0 = all modules now have canonical placement.
Exit code 1 = at least one module's manifest could NOT be canonicalised
              (no synonym match, no moduleAlias entry). Prints the failures.
"""
import json, subprocess, sys, os, argparse

ap = argparse.ArgumentParser()
ap.add_argument('--enum', default='/etc/zorbit/enum-placement-canonical.json')
ap.add_argument('--env-prefix', default='ze')
ap.add_argument('--dry-run', action='store_true')
args = ap.parse_args()

if not os.path.exists(args.enum):
    print(f'ERROR: enum file not found at {args.enum}', file=sys.stderr)
    sys.exit(2)

ENUM = json.load(open(args.enum))


def psql(db, sql, parse_row=False):
    cmd = ['docker', 'exec', 'zs-pg', 'psql', '-U', 'zorbit', '-d', db, '-tAF\t', '-c', sql]
    out = subprocess.check_output(cmd, text=True)
    if parse_row:
        return [l.split('\t', 1) for l in out.strip().split('\n') if l.strip()]
    return out


def canonical_scaffold(value):
    """Map any string to a canonical scaffold name. Returns None if cannot."""
    if not value:
        return None
    if value in ENUM['scaffold']['values']:
        return value
    if value in ENUM['scaffold']['synonyms']:
        return ENUM['scaffold']['synonyms'][value]
    return None


def canonical_business_line(value):
    if not value:
        return None
    if value in ENUM['businessLine']['values']:
        return value
    if value in ENUM['businessLine']['synonyms']:
        return ENUM['businessLine']['synonyms'][value]
    return None


def valid_capability_area(scaffold, business_line, capability_area):
    """Check if capabilityArea is allowed under this scaffold/businessLine."""
    by_scaffold = ENUM['capabilityArea']['byScaffold']
    if scaffold == 'Business Lines (Insurance)':
        if business_line not in by_scaffold[scaffold]:
            return False
        return capability_area in by_scaffold[scaffold][business_line]
    if scaffold not in by_scaffold:
        return False
    return capability_area in by_scaffold[scaffold]


def fixed_placement_for(module_id, current_placement):
    """Return a new placement dict for this module, or None if undecidable."""
    cur = current_placement or {}
    sc_in = cur.get('scaffold')
    bl_in = cur.get('businessLine')
    ca_in = cur.get('capabilityArea')

    # 1. Try to canonicalise current values via synonym map.
    sc_out = canonical_scaffold(sc_in)
    bl_out = canonical_business_line(bl_in) if bl_in else None
    ca_out = ca_in

    # 2. Validate capabilityArea against scaffold (and businessLine if applicable).
    if sc_out and ca_out and not valid_capability_area(sc_out, bl_out, ca_out):
        ca_out = None  # will be overridden by alias below if available

    # 3. Fall back to moduleAlias if we still don't have a complete fix.
    alias = ENUM['moduleAlias']['mappings'].get(module_id)
    if alias:
        sc_out = sc_out or alias.get('scaffold')
        bl_out = bl_out or alias.get('businessLine')
        ca_out = ca_out or alias.get('capabilityArea')
        # If alias-provided values pass validation, use them; otherwise drop.
        if not valid_capability_area(sc_out, bl_out, ca_out):
            # Try alias verbatim — it's the authoritative source if matched.
            sc_out = alias.get('scaffold')
            bl_out = alias.get('businessLine')
            ca_out = alias.get('capabilityArea')

    if not sc_out:
        return None  # cannot place

    new_p = dict(cur)
    new_p['scaffold'] = sc_out
    if sc_out == 'Business Lines (Insurance)':
        if bl_out:
            new_p['businessLine'] = bl_out
        else:
            return None
    else:
        new_p.pop('businessLine', None)
    if ca_out:
        new_p['capabilityArea'] = ca_out
    return new_p


def patch_db(db, table, key_col):
    print(f'\n=== Patching {db}.{table} ===')
    col = 'manifest_data' if table == 'modules' else 'manifest'
    rows = psql(db, f"SELECT {key_col}, COALESCE({col}, '{{}}'::jsonb)::text FROM {table} ORDER BY {key_col}", parse_row=True)
    fixed_count = 0
    skipped = []
    unchanged = 0
    for r in rows:
        if len(r) != 2:
            continue
        mod_id, manifest_str = r
        try:
            manifest = json.loads(manifest_str) if manifest_str.strip() else {}
        except Exception as e:
            skipped.append((mod_id, f'invalid JSON: {e}'))
            continue
        cur_placement = manifest.get('placement', {})
        new_placement = fixed_placement_for(mod_id, cur_placement)
        if new_placement is None:
            skipped.append((mod_id, 'no canonical placement found (no synonym, no alias)'))
            continue
        if new_placement == cur_placement:
            unchanged += 1
            continue
        manifest['placement'] = new_placement
        new_str = json.dumps(manifest).replace("'", "''")
        col = 'manifest_data' if table == 'modules' else 'manifest'
        if not args.dry_run:
            psql(db, f"UPDATE {table} SET {col} = '{new_str}'::jsonb WHERE {key_col} = '{mod_id}'")
        fixed_count += 1
        print(f'  FIX {mod_id}: {cur_placement.get("scaffold","-")} → {new_placement["scaffold"]}'
              f' / line={new_placement.get("businessLine","-")}'
              f' / area={new_placement.get("capabilityArea","-")}')
    print(f'  fixed={fixed_count} unchanged={unchanged} skipped={len(skipped)}')
    if skipped:
        print('  SKIPPED (need alias entry or canonical synonym):')
        for m, why in skipped:
            print(f'    - {m}: {why}')
    return fixed_count, skipped


fixed_total = 0
all_skipped = []
for db, table, key in [
    ('zorbit_module_registry', 'modules', 'module_id'),
    ('zorbit_navigation', 'registered_modules', 'module_id'),
]:
    f, s = patch_db(db, table, key)
    fixed_total += f
    all_skipped.extend((db, m, why) for (m, why) in s)

# Restart navigation so it rehydrates from the now-canonical DB
if not args.dry_run:
    print('\nRestarting navigation service...')
    subprocess.run(['docker', 'exec', f'{args.env_prefix}-core', 'pm2', 'restart', 'zorbit-navigation'], capture_output=True)
    print('Restart issued.')

# Final report
print('\n' + '=' * 60)
print(f'TOTAL FIXES: {fixed_total}')
if all_skipped:
    print(f'UNFIXABLE: {len(all_skipped)}')
    for db, m, why in all_skipped:
        print(f'  {db}.{m}: {why}')
    sys.exit(1)
print('All modules canonicalised.')
sys.exit(0)
