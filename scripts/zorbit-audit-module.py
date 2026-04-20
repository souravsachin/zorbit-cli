#!/usr/bin/env python3
"""
Zorbit Module Self-Audit
========================

Walks a module's repo and emits a timestamped audit report capturing:

  - BE routes   — every @Controller + @(Get|Post|Put|Patch|Delete) handler
  - FE routes   — every <Route path=...> and navigate('/...') inside the repo
  - FE comps    — every .tsx/.jsx React component
  - Manifest    — the module's registered navigation items + advertised beRoutes

Then classifies:

  - BE routes: ADVERTISED / USEFUL-UNADVERTISED / LEGACY
  - FE routes: MATCHES-MANIFEST / LEGACY / UNMATCHED
  - FE comps:  MANIFEST-COVERED / MODULE-SPECIFIC / SDK-CANDIDATE / DUPLICATE-LIKELY

Usage from a module repo root:
    python3 <path-to>/zorbit-audit-module.py [--out <dir>] [--module-id <slug>]

    --out:        where to write the audit (default: ./audits/)
    --module-id:  override slug auto-detection (uses zorbit-module-manifest.json)

Output:
  audits/<slug>-<YYYYMMDD-HHMMSS>.json   — machine-readable
  audits/<slug>-<YYYYMMDD-HHMMSS>.md     — human-readable summary
  audits/latest.json                     — symlink / copy to latest
  audits/latest.md                       — symlink / copy to latest

Exit 0 on success, non-zero if the repo isn't a Zorbit module (no manifest).
"""

from __future__ import annotations
import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


HTTP_DECORATORS = re.compile(r'@(Get|Post|Put|Patch|Delete|All)\s*\(\s*(?:[\'"`]([^\'"`]*)[\'"`])?\s*\)')
CONTROLLER_DECORATOR = re.compile(r'@Controller\s*\(\s*(?:[\'"`]([^\'"`]*)[\'"`])?\s*\)')
ROUTE_PATH = re.compile(r'<Route\s+[^>]*\bpath\s*=\s*[\'"]([^\'"]+)[\'"]')
NAVIGATE_CALL = re.compile(r'\bnavigate\s*\(\s*[\'"`]([^\'"`]+)[\'"`]')
EXPORT_DEFAULT = re.compile(r'export\s+default\s+(?:function\s+)?(\w+)')
EXPORT_NAMED = re.compile(r'export\s+(?:const|function)\s+(\w+)')

SKIP_DIRS = {'node_modules', 'dist', '.git', 'build', 'coverage', '.next', 'tmp', '.nuxt'}


@dataclass
class BeRoute:
    method: str
    path: str
    handler_file: str
    classification: str = ''


@dataclass
class FeRoute:
    path: str
    declared_in: str
    classification: str = ''


@dataclass
class FeComponent:
    name: str
    path: str
    loc: int
    classification: str = ''


@dataclass
class AuditReport:
    module_id: str
    module_name: str
    generated_at: str
    repo_root: str
    manifest_version: str
    counts: dict = field(default_factory=dict)
    be_routes: list = field(default_factory=list)
    fe_routes: list = field(default_factory=list)
    fe_components: list = field(default_factory=list)
    advertised_be_routes: list = field(default_factory=list)
    manifest_nav_items: list = field(default_factory=list)
    recommendations: list = field(default_factory=list)


def load_manifest(repo_root: Path) -> dict | None:
    candidates = [
        repo_root / 'zorbit-module-manifest.json',
        repo_root / 'manifest' / 'manifest.json',
        repo_root / 'manifest.json',
    ]
    for p in candidates:
        if p.exists():
            try:
                with p.open() as f:
                    return json.load(f)
            except Exception as e:
                print(f'WARN: failed to read {p}: {e}', file=sys.stderr)
    return None


def walk_files(root: Path, suffixes: tuple[str, ...]):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn.endswith(suffixes):
                yield Path(dirpath) / fn


def scan_be_routes(repo_root: Path) -> list[BeRoute]:
    out: list[BeRoute] = []
    src_dir = repo_root / 'src'
    if not src_dir.exists():
        return out
    for file in walk_files(src_dir, ('.ts',)):
        try:
            txt = file.read_text(errors='ignore')
        except Exception:
            continue
        if '@Controller' not in txt:
            continue
        # Find the controller base path
        ctrl_match = CONTROLLER_DECORATOR.search(txt)
        base = ctrl_match.group(1) if ctrl_match and ctrl_match.group(1) else ''
        if base and not base.startswith('/'):
            base = '/' + base
        for m in HTTP_DECORATORS.finditer(txt):
            method = m.group(1).upper()
            sub = m.group(2) or ''
            if sub and not sub.startswith('/'):
                sub = '/' + sub
            full = (base + sub).rstrip('/') or '/'
            out.append(BeRoute(method=method, path=full, handler_file=str(file.relative_to(repo_root))))
    return out


def scan_fe_routes_and_components(repo_root: Path) -> tuple[list[FeRoute], list[FeComponent]]:
    routes: list[FeRoute] = []
    components: list[FeComponent] = []
    for file in walk_files(repo_root, ('.tsx', '.jsx')):
        try:
            txt = file.read_text(errors='ignore')
        except Exception:
            continue
        # routes
        for m in ROUTE_PATH.finditer(txt):
            routes.append(FeRoute(path=m.group(1), declared_in=str(file.relative_to(repo_root))))
        for m in NAVIGATE_CALL.finditer(txt):
            routes.append(FeRoute(path=m.group(1), declared_in=str(file.relative_to(repo_root))))
        # components: one per file — use default export name, else first named, else filename
        name = None
        mdef = EXPORT_DEFAULT.search(txt)
        if mdef:
            name = mdef.group(1)
        else:
            mnamed = EXPORT_NAMED.search(txt)
            if mnamed:
                name = mnamed.group(1)
        if not name:
            name = file.stem
        components.append(
            FeComponent(name=name, path=str(file.relative_to(repo_root)), loc=txt.count('\n'))
        )
    return routes, components


def _strip_api_slug_prefix(path: str) -> str:
    """Normalise '/api/<slug>/api/v1/...' and '/api/<slug>/...' down to the /api/v1/... tail.

    Nginx prefixes /api/<slug>/ when routing from edge to the module; controllers
    inside the module therefore mount at /api/v1/... without the slug. We want
    matches regardless of which side added/stripped the prefix.
    """
    # Drop zero or one leading /api/<slug> prefix
    m = re.match(r'^/api/[^/]+(/api/.*)$', path)
    if m:
        return m.group(1)
    m = re.match(r'^/api/[^/]+(/.*)$', path)
    # Only strip if what follows looks like /api/v1/...
    if m and m.group(1).startswith('/api/'):
        return m.group(1)
    return path


def _normalise_route(path: str) -> set[str]:
    """Return the set of canonical shapes that should compare as equivalent."""
    base = re.sub(r'\{\{[^}]+\}\}', ':var', path).rstrip('/') or '/'
    base = re.sub(r':\w+', ':var', base)
    tail = _strip_api_slug_prefix(base)
    # Also try the full /api/<anything>/api/v1 stripped form
    tail2 = _strip_api_slug_prefix(tail)
    return {base, tail, tail2}


def classify_be_routes(be: list[BeRoute], advertised: set[str]) -> None:
    legacy_hints = ('/legacy/', '/deprecated/', '/v0/', '/old/')
    adv_shapes: set[str] = set()
    for a in advertised:
        adv_shapes |= _normalise_route(a)

    for r in be:
        shapes = _normalise_route(r.path)
        if shapes & adv_shapes:
            r.classification = 'ADVERTISED'
        elif any(hint in r.path for hint in legacy_hints):
            r.classification = 'LEGACY'
        else:
            r.classification = 'USEFUL-UNADVERTISED'


def classify_fe_routes(fe: list[FeRoute], manifest_feroutes: set[str]) -> None:
    norm_manifest = {r.rstrip('/') for r in manifest_feroutes}
    for r in fe:
        p = r.path.rstrip('/')
        if p in norm_manifest or any(p == mp or p.startswith(mp + '/') for mp in norm_manifest):
            r.classification = 'MATCHES-MANIFEST'
        elif any(p.startswith(pre) for pre in ('/admin/', '/hi-decisioning/', '/hi-quotation/',
                                                '/help/', '/observability/', '/old-', '/legacy/',
                                                '/org/')):
            r.classification = 'LEGACY'
        elif p.startswith('/m/'):
            r.classification = 'MATCHES-MANIFEST-CANDIDATE'
        else:
            r.classification = 'UNMATCHED'


def classify_fe_components(comps: list[FeComponent], manifest_has_datatable: bool,
                            manifest_has_formrenderer: bool) -> None:
    # Heuristic: boilerplate pages are SDK-candidates
    BOILERPLATE = {'HubPage', 'SetupPage', 'DeploymentsPage', 'HelpPage', 'OverviewPage'}
    # Components likely covered by DataTable now
    DATATABLE_LIKELY = re.compile(r'(List|Table|Page)$', re.IGNORECASE)

    for c in comps:
        if c.name in BOILERPLATE:
            c.classification = 'SDK-CANDIDATE (ScaffoldPages family)'
        elif manifest_has_datatable and DATATABLE_LIKELY.search(c.name) and 'Detail' not in c.name:
            c.classification = 'MANIFEST-COVERED (DataTable)'
        elif c.loc < 80:
            c.classification = 'SMALL (review — likely SDK-graduation candidate)'
        else:
            c.classification = 'MODULE-SPECIFIC'


def extract_manifest_artifacts(manifest: dict) -> tuple[set[str], set[str], list[dict], bool, bool]:
    advertised = set()
    feroutes = set()
    nav_items = []
    has_datatable = False
    has_formrenderer = False

    nav = (manifest.get('navigation') or {}).get('sections', []) or []
    for sec in nav:
        for item in sec.get('items', []) or []:
            if item.get('beRoute'):
                advertised.add(item['beRoute'])
            if item.get('feRoute'):
                feroutes.add(item['feRoute'])
            if 'DataTable' in (item.get('feComponent') or ''):
                has_datatable = True
            if 'FormRenderer' in (item.get('feComponent') or ''):
                has_formrenderer = True
            nav_items.append({
                'section': sec.get('label'),
                'label': item.get('label'),
                'feRoute': item.get('feRoute'),
                'beRoute': item.get('beRoute'),
                'feComponent': item.get('feComponent'),
            })

    db = manifest.get('db') or {}
    for op_name, op in (db.get('operations') or {}).items():
        if isinstance(op, dict) and op.get('beRoute'):
            advertised.add(op['beRoute'])

    return advertised, feroutes, nav_items, has_datatable, has_formrenderer


def generate_recommendations(report: AuditReport) -> list[str]:
    recs = []
    counts = report.counts
    total_be = counts.get('be_routes_total', 0)
    adv = counts.get('be_routes_advertised', 0)
    if total_be and adv / total_be < 0.30:
        pct = int(100 * adv / total_be)
        recs.append(
            f'Advertise more BE routes in manifest ({pct}% currently — '
            f'surface {total_be - adv} useful-unadvertised handlers).'
        )
    if counts.get('fe_routes_legacy', 0) > 0:
        recs.append(
            f'Retire {counts["fe_routes_legacy"]} legacy FE routes '
            '(replace with /m/{slug}/... manifest-driven routes).'
        )
    if counts.get('fe_components_sdk_candidate', 0) > 0:
        recs.append(
            f'Graduate {counts["fe_components_sdk_candidate"]} boilerplate components '
            'to the central SDK (ScaffoldPages family).'
        )
    if counts.get('fe_components_manifest_covered', 0) > 0:
        recs.append(
            f'Retire {counts["fe_components_manifest_covered"]} components '
            'superseded by zorbit-pfs-datatable:DataTable or zorbit-pfs-form_builder:FormRenderer.'
        )
    if not recs:
        recs.append('No high-impact pruning opportunities found. Module is well-advertised.')
    return recs


def write_reports(report: AuditReport, out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = report.generated_at.replace(':', '').replace('-', '').replace('.', '').replace('+0000', '').replace('T', '-')[:15]
    slug = report.module_id.replace('/', '_')
    json_path = out_dir / f'{slug}-{ts}.json'
    md_path = out_dir / f'{slug}-{ts}.md'
    with json_path.open('w') as f:
        json.dump(asdict(report), f, indent=2, default=str)

    with md_path.open('w') as f:
        f.write(f'# Module audit — {report.module_id}\n\n')
        f.write(f'- Generated: {report.generated_at}\n')
        f.write(f'- Manifest version: {report.manifest_version}\n')
        f.write(f'- Repo: `{report.repo_root}`\n\n')

        f.write('## Counts\n\n')
        for k, v in report.counts.items():
            f.write(f'- {k}: {v}\n')
        f.write('\n')

        f.write('## Top recommendations\n\n')
        for r in report.recommendations:
            f.write(f'- {r}\n')
        f.write('\n')

        f.write('## BE routes\n\n')
        f.write('| Method | Path | Classification | Handler |\n')
        f.write('|--------|------|----------------|---------|\n')
        for r in report.be_routes[:500]:
            f.write(f'| {r["method"]} | `{r["path"]}` | {r["classification"]} | `{r["handler_file"]}` |\n')
        f.write('\n')

        f.write('## FE routes\n\n')
        f.write('| Path | Classification | Declared in |\n')
        f.write('|------|----------------|-------------|\n')
        for r in report.fe_routes[:500]:
            f.write(f'| `{r["path"]}` | {r["classification"]} | `{r["declared_in"]}` |\n')
        f.write('\n')

        f.write('## FE components\n\n')
        f.write('| Name | LOC | Classification | Path |\n')
        f.write('|------|-----|----------------|------|\n')
        for c in sorted(report.fe_components, key=lambda x: -x['loc'])[:200]:
            f.write(f'| {c["name"]} | {c["loc"]} | {c["classification"]} | `{c["path"]}` |\n')
        f.write('\n')

    # latest pointers (copy, not symlink — safer across FS)
    (out_dir / 'latest.json').write_text(json_path.read_text())
    (out_dir / 'latest.md').write_text(md_path.read_text())

    return json_path, md_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='./audits', help='Output directory')
    ap.add_argument('--module-id', help='Override slug (else read from manifest)')
    ap.add_argument('--repo', default='.', help='Repo root (default cwd)')
    args = ap.parse_args()

    repo_root = Path(args.repo).resolve()
    manifest = load_manifest(repo_root)
    if manifest is None:
        print(f'ERROR: No Zorbit manifest found under {repo_root} — is this a module repo?', file=sys.stderr)
        return 2

    module_id = args.module_id or manifest.get('moduleId') or repo_root.name
    module_name = manifest.get('moduleName') or module_id
    manifest_version = manifest.get('version') or manifest.get('manifestVersion') or 'unknown'

    advertised, feroutes, nav_items, has_dt, has_fr = extract_manifest_artifacts(manifest)
    be = scan_be_routes(repo_root)
    fe, comps = scan_fe_routes_and_components(repo_root)
    classify_be_routes(be, advertised)
    classify_fe_routes(fe, feroutes)
    classify_fe_components(comps, has_dt, has_fr)

    counts = {
        'be_routes_total': len(be),
        'be_routes_advertised': sum(1 for r in be if r.classification == 'ADVERTISED'),
        'be_routes_useful_unadvertised': sum(1 for r in be if r.classification == 'USEFUL-UNADVERTISED'),
        'be_routes_legacy': sum(1 for r in be if r.classification == 'LEGACY'),
        'fe_routes_total': len(fe),
        'fe_routes_matches_manifest': sum(1 for r in fe if r.classification in ('MATCHES-MANIFEST', 'MATCHES-MANIFEST-CANDIDATE')),
        'fe_routes_legacy': sum(1 for r in fe if r.classification == 'LEGACY'),
        'fe_routes_unmatched': sum(1 for r in fe if r.classification == 'UNMATCHED'),
        'fe_components_total': len(comps),
        'fe_components_sdk_candidate': sum(1 for c in comps if 'SDK-CANDIDATE' in c.classification),
        'fe_components_manifest_covered': sum(1 for c in comps if 'MANIFEST-COVERED' in c.classification),
        'manifest_nav_items': len(nav_items),
        'manifest_advertised_be_routes': len(advertised),
    }

    report = AuditReport(
        module_id=module_id,
        module_name=module_name,
        generated_at=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S+0000'),
        repo_root=str(repo_root),
        manifest_version=str(manifest_version),
        counts=counts,
        be_routes=[asdict(r) for r in be],
        fe_routes=[asdict(r) for r in fe],
        fe_components=[asdict(c) for c in comps],
        advertised_be_routes=sorted(advertised),
        manifest_nav_items=nav_items,
    )
    report.recommendations = generate_recommendations(report)

    out_dir = Path(args.out) if os.path.isabs(args.out) else repo_root / args.out
    json_path, md_path = write_reports(report, out_dir)

    print(f'✓ audit complete: {module_id} (manifest v{manifest_version})')
    print(f'  JSON: {json_path}')
    print(f'  MD:   {md_path}')
    print(f'  Counts: BE {counts["be_routes_advertised"]}/{counts["be_routes_total"]} advertised, '
          f'FE routes {counts["fe_routes_legacy"]} legacy, '
          f'FE comps {counts["fe_components_sdk_candidate"]} SDK-candidates')
    return 0


if __name__ == '__main__':
    sys.exit(main())
