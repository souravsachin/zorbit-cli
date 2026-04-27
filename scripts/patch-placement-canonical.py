#!/usr/bin/env python3
"""
patch-placement-canonical.py
============================

Idempotent canonicaliser for ALL `02_repos/zorbit-{cor,pfs,app,ai}-*` and
adjacent module manifests. Maps legacy display-name strings inside
`placement.scaffold` / `placement.businessLine` to canonical lowercase
slugs, normalises `placement.scaffoldSortOrder` to the deterministic L1
order from owner MSG-101 (2026-04-27).

Inputs
------
1. zorbit-core/platform-spec/placement-canonical-mapping.json
   - scaffold_synonyms { displayName : slug }
   - businessLine_synonyms { displayName : slug }
   - scaffold_sortOrder { slug : int }
2. zorbit-core/platform-spec/slug-translations.json (optional fallback)
   - moduleAlias { repoName : { scaffold, businessLine?, capabilityArea? } }

Operation
---------
For every `02_repos/*/zorbit-module-manifest.json`:
  - Read placement (or empty {})
  - Resolve placement.scaffold via scaffold_synonyms (case-sensitive then
    case-insensitive); fall back to slug-translations.moduleAlias on miss.
  - Resolve placement.businessLine via businessLine_synonyms (only if
    scaffold is 'business').
  - Drop businessLine entirely when scaffold is NOT 'business'.
  - Set placement.scaffoldSortOrder from scaffold_sortOrder[scaffold].
  - Leave capabilityArea / sortOrder / edition untouched (those are
    handled by other patchers / owner curation).
  - Diff vs. original; rewrite the file only if changed.

Modes
-----
--dry-run     Report what WOULD change. No file writes.
              (default mode is to apply.)
--repos-root  Override default 02_repos location.
--report      Path to write a JSON summary; defaults to stdout.

Exit codes
----------
0  All manifests now canonical (zero unresolved scaffolds).
1  At least one manifest has a scaffold value that could NOT be resolved
   via either synonym table OR moduleAlias. Manual fix required.
2  Required input file (mapping or slug-translations) missing.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Optional

# ---------- defaults -----------------------------------------------------

DEFAULT_REPOS_ROOT = "/Users/s/workspace/zorbit/02_repos"
DEFAULT_MAPPING = (
    "{repos_root}/zorbit-core/platform-spec/placement-canonical-mapping.json"
)
DEFAULT_TRANSLATIONS = (
    "{repos_root}/zorbit-core/platform-spec/slug-translations.json"
)


# ---------- helpers ------------------------------------------------------

def load_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def save_json(path: str, obj: Any) -> None:
    """Write JSON with 2-space indent + trailing newline (matches existing repo style)."""
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def find_manifests(repos_root: str) -> list[Path]:
    root = Path(repos_root)
    return sorted(root.glob("*/zorbit-module-manifest.json"))


def resolve_via_synonyms(
    raw: Optional[str], synonyms: dict[str, str]
) -> Optional[str]:
    """Try direct lookup, then case-insensitive."""
    if raw is None:
        return None
    if raw in synonyms:
        return synonyms[raw]
    # case-insensitive fallback
    lc = raw.lower()
    for key, val in synonyms.items():
        if key.lower() == lc:
            return val
    return None


def resolve_via_module_alias(
    repo_name: str, module_aliases: dict[str, dict]
) -> Optional[dict]:
    return module_aliases.get(repo_name)


def canonicalise(
    repo_name: str,
    placement: dict,
    mapping: dict,
    module_aliases: dict,
) -> tuple[dict, list[str]]:
    """
    Returns (new_placement, problems).
    problems is a list of human-readable strings; an empty list means OK.
    """
    problems: list[str] = []
    new_placement = dict(placement) if placement else {}

    raw_scaffold = new_placement.get("scaffold")
    canonical_scaffold = resolve_via_synonyms(
        raw_scaffold, mapping["scaffold_synonyms"]
    )

    # If synonyms didn't resolve and we have a moduleAlias, use it.
    alias = resolve_via_module_alias(repo_name, module_aliases)
    if not canonical_scaffold and alias:
        canonical_scaffold = alias.get("scaffold")

    if not canonical_scaffold:
        problems.append(
            f"scaffold {raw_scaffold!r} not resolvable via synonyms or moduleAlias"
        )
        return new_placement, problems

    new_placement["scaffold"] = canonical_scaffold
    new_placement["scaffoldSortOrder"] = mapping["scaffold_sortOrder"][
        canonical_scaffold
    ]

    if canonical_scaffold == "business":
        # businessLine handling
        raw_bl = new_placement.get("businessLine")
        # Allow falling back to alias.businessLine when manifest is missing it
        if not raw_bl and alias:
            raw_bl = alias.get("businessLine")
        canonical_bl = resolve_via_synonyms(
            raw_bl, mapping["businessLine_synonyms"]
        )
        if raw_bl and not canonical_bl:
            problems.append(
                f"businessLine {raw_bl!r} not resolvable via synonyms"
            )
        elif canonical_bl:
            new_placement["businessLine"] = canonical_bl

        # capabilityArea fallback from alias if missing
        if not new_placement.get("capabilityArea") and alias and alias.get(
            "capabilityArea"
        ):
            new_placement["capabilityArea"] = alias["capabilityArea"]
    else:
        # businessLine only applies to business scaffold; remove if present.
        if "businessLine" in new_placement:
            del new_placement["businessLine"]

    return new_placement, problems


# ---------- main ---------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--repos-root", default=DEFAULT_REPOS_ROOT)
    ap.add_argument("--mapping", default=None)
    ap.add_argument("--translations", default=None)
    ap.add_argument("--report", default=None, help="Write JSON summary to path")
    args = ap.parse_args()

    repos_root = os.path.abspath(args.repos_root)
    mapping_path = args.mapping or DEFAULT_MAPPING.format(repos_root=repos_root)
    translations_path = args.translations or DEFAULT_TRANSLATIONS.format(
        repos_root=repos_root
    )

    if not os.path.exists(mapping_path):
        print(f"ERROR: mapping not found: {mapping_path}", file=sys.stderr)
        return 2
    mapping = load_json(mapping_path)

    module_aliases: dict[str, dict] = {}
    if os.path.exists(translations_path):
        translations = load_json(translations_path)
        ma = translations.get("moduleAlias", {})
        # filter out the leading underscore-prefixed help keys
        module_aliases = {k: v for k, v in ma.items() if not k.startswith("_")}
    else:
        print(
            f"WARN: slug-translations.json not found at {translations_path}; "
            f"moduleAlias fallback disabled.",
            file=sys.stderr,
        )

    manifests = find_manifests(repos_root)
    print(f"Scanned {len(manifests)} manifests under {repos_root}")

    summary = {
        "version": mapping.get("version", "?"),
        "dry_run": args.dry_run,
        "total_manifests": len(manifests),
        "changed": [],
        "unchanged": [],
        "problems": [],
    }

    for manifest_path in manifests:
        repo_name = manifest_path.parent.name
        try:
            doc = load_json(str(manifest_path))
        except Exception as exc:
            summary["problems"].append(
                {"repo": repo_name, "error": f"load failed: {exc}"}
            )
            continue

        original_placement = doc.get("placement", {}) or {}
        new_placement, problems = canonicalise(
            repo_name, original_placement, mapping, module_aliases
        )

        if problems:
            summary["problems"].append(
                {"repo": repo_name, "problems": problems}
            )

        if new_placement == original_placement:
            summary["unchanged"].append(repo_name)
            continue

        diff = {
            "before": original_placement,
            "after": new_placement,
        }
        summary["changed"].append({"repo": repo_name, "diff": diff})

        if not args.dry_run:
            doc["placement"] = new_placement
            save_json(str(manifest_path), doc)

    # ---- print report ---------------------------------------------------
    print("")
    print(f"Changed   : {len(summary['changed'])}")
    print(f"Unchanged : {len(summary['unchanged'])}")
    print(f"Problems  : {len(summary['problems'])}")
    print("")

    if summary["changed"]:
        print("--- CHANGED ---")
        for entry in summary["changed"]:
            print(f"  {entry['repo']}")
            print(f"    BEFORE: {json.dumps(entry['diff']['before'])}")
            print(f"    AFTER : {json.dumps(entry['diff']['after'])}")
        print("")

    if summary["problems"]:
        print("--- PROBLEMS ---")
        for p in summary["problems"]:
            print(f"  {p}")
        print("")

    if args.report:
        save_json(args.report, summary)
        print(f"Report written to {args.report}")

    return 1 if summary["problems"] else 0


if __name__ == "__main__":
    sys.exit(main())
