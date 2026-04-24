#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# _gates_bundle_dump.py — internal helper for gates-harness.sh
# ---------------------------------------------------------------------------
# Reads bundles.yaml and prints:
#     "<containers> | <shared> | <modules>"
# (space-delimited, pipe-separated sections)
# ---------------------------------------------------------------------------
import sys
import yaml


def main():
    bundles_yaml, env_prefix = sys.argv[1], sys.argv[2]
    with open(bundles_yaml) as f:
        data = yaml.safe_load(f)

    bundle_names = list(data["bundles"].keys())  # core, pfs, apps, ai, web
    containers = [f"{env_prefix}-{b}" for b in bundle_names]
    shared = [s["name"] for s in data.get("shared", [])]

    modules = []
    for b in bundle_names:
        for svc in data["bundles"][b]["services"]:
            modules.append(svc["repo"])

    print(
        " ".join(containers)
        + "|"
        + " ".join(shared)
        + "|"
        + " ".join(modules)
    )


if __name__ == "__main__":
    main()
