#!/usr/bin/env bash
#
# migrate-compose-to-vault.sh
#
# Scan a docker-compose.yml for known credential env vars, rewrite each
# to a `zorbit:vault:<namespace>` placeholder, and emit:
#
#   <input>.vault.yml          patched compose (non-destructive; never
#                              overwrites the original)
#   <input>.vault-manifest.yaml list of every secret that needs to be
#                              pre-populated in the vault BEFORE you
#                              switch the service over
#
# This tool does NOT auto-push secrets. The manifest is for the owner
# to review and then feed into `vault.sh put` (one at a time, with the
# value read off-channel).
#
# Usage:
#   migrate-compose-to-vault.sh \
#       --input  <path-to-compose.yml> \
#       [--env   zorbit-dev|zorbit-uat|zorbit-prod]  (default: zorbit-dev)
#       [--module <owning-module-slug>]              (default: derived)
#       [--dry-run]                                  (print, don't write)
#
# Known-sensitive env-var patterns:
#   Exact:       JWT_SECRET, *_PASSWORD, *_TOKEN, *_SECRET, *_KEY (except
#                KEY/FOREIGN_KEY trivial ones), DATABASE_*, MONGO_*,
#                POSTGRES_*, KAFKA_*, REDIS_PASSWORD, *_API_KEY,
#                OAUTH_*_CLIENT_SECRET, SAML_*_CERT, HMAC_KEY
#   Containing:  password, secret, token, api_key, client_secret,
#                connection-string, conn_str, private_key, master_key,
#                mongodb+srv://, postgres://, mysql://
#
# The matcher is INTENTIONALLY conservative — it prefers false positives
# (more things routed via vault) over false negatives. You can exempt
# specific vars via --exempt name1,name2,...
#
set -euo pipefail

INPUT=""
ENV_SLUG="zorbit-dev"
MODULE_OVERRIDE=""
DRY_RUN=false
EXEMPT_LIST=""

usage() {
  sed -n '2,50p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)   INPUT="$2"; shift 2 ;;
    --env)     ENV_SLUG="$2"; shift 2 ;;
    --module)  MODULE_OVERRIDE="$2"; shift 2 ;;
    --exempt)  EXEMPT_LIST="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${INPUT}" ]]; then
  echo "error: --input <path> required" >&2
  usage
  exit 1
fi
if [[ ! -f "${INPUT}" ]]; then
  echo "error: file not found: ${INPUT}" >&2
  exit 1
fi

# Derive owning module from the compose file's parent dir if not given.
if [[ -z "${MODULE_OVERRIDE}" ]]; then
  MODULE_OVERRIDE="$(basename "$(cd "$(dirname "${INPUT}")" && pwd)")"
fi

STEM="${INPUT%.yml}"
STEM="${STEM%.yaml}"
OUTPUT_COMPOSE="${STEM}.vault.yml"
OUTPUT_MANIFEST="${STEM}.vault-manifest.yaml"

python3 - "${INPUT}" "${ENV_SLUG}" "${MODULE_OVERRIDE}" "${EXEMPT_LIST}" "${OUTPUT_COMPOSE}" "${OUTPUT_MANIFEST}" "${DRY_RUN}" <<'PY'
import re
import sys
import os

(
    input_path,
    env_slug,
    module_slug,
    exempt_csv,
    out_compose,
    out_manifest,
    dry_run_str,
) = sys.argv[1:8]
dry_run = dry_run_str == "true"
exempt = {e.strip() for e in exempt_csv.split(",") if e.strip()}

# --- Heuristic: is this env var name / value sensitive? ----------------
NAME_EXACT = {
    "JWT_SECRET",
    "HMAC_KEY",
    "PLATFORM_MODULE_SECRET",
    "MODULE_HMAC_SECRET",
    "SESSION_SECRET",
    "COOKIE_SECRET",
    "ENCRYPTION_KEY",
    "MASTER_KEY",
    "SECRETS_VAULT_KEK",
    "REDIS_PASSWORD",
    "SMTP_PASSWORD",
    "DATABASE_HOST",
    "DATABASE_USER",
    "DATABASE_USERNAME",
    "DATABASE_PASSWORD",
    "DATABASE_URL",
    "DATABASE_NAME",
    "MONGO_URI",
    "MONGODB_URI",
    "MONGO_URL",
    "POSTGRES_PASSWORD",
    "POSTGRES_USER",
    "POSTGRES_DB",
    "KAFKA_BROKERS",
    "KAFKA_USERNAME",
    "KAFKA_PASSWORD",
    "KAFKA_SASL_PASSWORD",
}
NAME_SUFFIXES = (
    "_PASSWORD",
    "_SECRET",
    "_TOKEN",
    "_API_KEY",
    "_CLIENT_SECRET",
    "_PRIVATE_KEY",
    "_HMAC_KEY",
    "_ENCRYPTION_KEY",
    "_CERT",
    "_CERTIFICATE",
    "_KEYSTORE",
)

VALUE_MARKERS_RE = re.compile(
    r"(?i)(mongodb(\+srv)?://|postgres(ql)?://|mysql://|redis://|amqp://|sftp://)"
)

ZORBIT_MODULE_PREFIXES = ("zorbit-cor-", "zorbit-pfs-", "zorbit-app-", "zorbit-sdk-")

def resolve_owning_module(service_name, override_slug: str) -> str:
    """
    Return the owning-module slug for vault keys.
    Rules:
      - If the service name is already a Zorbit module slug, use it.
      - Else if the override is a Zorbit slug, use that.
      - Else fall back to "_shared" (keys under _shared bypass the
        module-registry check — owner must review and retarget).
    """
    if service_name and service_name.startswith(ZORBIT_MODULE_PREFIXES):
        return service_name
    if override_slug and override_slug.startswith(ZORBIT_MODULE_PREFIXES):
        return override_slug
    return "_shared"


def is_sensitive(name: str, value: str) -> bool:
    if name in exempt:
        return False
    if name in NAME_EXACT:
        return True
    for suf in NAME_SUFFIXES:
        if name.endswith(suf):
            return True
    if value and VALUE_MARKERS_RE.search(value):
        return True
    # Private keys that appear inline
    if value and "-----BEGIN " in value:
        return True
    return False

# --- Read the compose file line-by-line so we preserve formatting. ------
# docker-compose YAML in practice is simple enough that a line-based
# rewrite is safer than a full round-trip through a YAML library (which
# would normalise quoting + ordering). We only care about environment
# entries, which are either `NAME: value` or `- NAME=value`.

with open(input_path, "r", encoding="utf-8") as f:
    raw = f.read()

lines = raw.splitlines()
new_lines = []
manifest_rows = []

# Track where we are. We only rewrite lines that sit under an
# `environment:` key at any indent, until we leave the environment block.
def indent_of(s: str) -> int:
    i = 0
    while i < len(s) and s[i] == " ":
        i += 1
    return i

in_env_block = False
env_indent = -1
# Also track service name if we can see it.
service_name = module_slug

service_header_re = re.compile(r"^\s{2,}([a-z0-9][a-z0-9_.-]*):\s*$")
env_key_re = re.compile(r"^\s+environment:\s*$")
map_entry_re = re.compile(r"^(\s+)([A-Z][A-Z0-9_]+)\s*:\s*(.*)$")
list_entry_re = re.compile(r"^(\s+)-\s*([A-Z][A-Z0-9_]+)\s*=\s*(.*)$")

for line in lines:
    # Detect service header (NOT inside a nested key — roughly 2 space indent)
    m = service_header_re.match(line)
    if m and indent_of(line) == 2:
        service_name = m.group(1)
        in_env_block = False
        new_lines.append(line)
        continue

    if env_key_re.match(line):
        in_env_block = True
        env_indent = indent_of(line)
        new_lines.append(line)
        continue

    if in_env_block:
        # Leave block when indent drops to env_indent or less AND line is not blank.
        stripped = line.strip()
        if stripped and indent_of(line) <= env_indent and not stripped.startswith("- "):
            in_env_block = False
            new_lines.append(line)
            continue

        # mapping form: NAME: value
        mm = map_entry_re.match(line)
        if mm:
            prefix, name, value = mm.group(1), mm.group(2), mm.group(3).strip()
            # Strip surrounding quotes for the heuristic
            raw_value = value
            if (value.startswith("'") and value.endswith("'")) or (
                value.startswith('"') and value.endswith('"')
            ):
                raw_value = value[1:-1]
            if is_sensitive(name, raw_value):
                ns_module = resolve_owning_module(service_name, module_slug)
                # specifier: lowercased, hyphen-separated
                specifier = name.lower().replace("_", "-")
                ns_short = f"{env_slug}/{service_name or ns_module}/{specifier}"
                replacement = f"zorbit:vault:{ns_short}"
                new_lines.append(f'{prefix}{name}: "{replacement}"')
                manifest_rows.append(
                    {
                        "compose_var": name,
                        "service": service_name,
                        "original_value": raw_value,
                        "vault_namespace": ns_short,
                        "vault_key": f"platform.{ns_module}.credentials.{env_slug}-{specifier}",
                    }
                )
                continue

        # list form: - NAME=value
        ll = list_entry_re.match(line)
        if ll:
            prefix, name, value = ll.group(1), ll.group(2), ll.group(3).strip()
            raw_value = value
            if (value.startswith("'") and value.endswith("'")) or (
                value.startswith('"') and value.endswith('"')
            ):
                raw_value = value[1:-1]
            if is_sensitive(name, raw_value):
                ns_module = resolve_owning_module(service_name, module_slug)
                specifier = name.lower().replace("_", "-")
                ns_short = f"{env_slug}/{service_name or ns_module}/{specifier}"
                replacement = f"zorbit:vault:{ns_short}"
                new_lines.append(f"{prefix}- {name}={replacement}")
                manifest_rows.append(
                    {
                        "compose_var": name,
                        "service": service_name,
                        "original_value": raw_value,
                        "vault_namespace": ns_short,
                        "vault_key": f"platform.{ns_module}.credentials.{env_slug}-{specifier}",
                    }
                )
                continue

    new_lines.append(line)

patched = "\n".join(new_lines)
if not patched.endswith("\n"):
    patched += "\n"

# Build the manifest as plain YAML (no dep on pyyaml).
def yaml_escape(s: str) -> str:
    if s == "":
        return '""'
    if any(c in s for c in ':#\n"\'&*!|>%@`'):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s

manifest_lines = []
manifest_lines.append(f"# .vault-manifest.yaml — generated by migrate-compose-to-vault.sh")
manifest_lines.append(f"# source: {os.path.basename(input_path)}")
manifest_lines.append(f"# env:    {env_slug}")
manifest_lines.append(f"# module: {module_slug}")
manifest_lines.append(f"# count:  {len(manifest_rows)}")
manifest_lines.append(f"#")
manifest_lines.append(f"# Review each row BEFORE pushing to the vault. Use:")
manifest_lines.append(f"#   zorbit-cli/scripts/vault.sh put --key <vault_key>")
manifest_lines.append(f"# and enter the value at the prompt (it will never be echoed).")
manifest_lines.append(f"")
manifest_lines.append("secrets:")
for row in manifest_rows:
    manifest_lines.append(f"  - compose_var: {row['compose_var']}")
    manifest_lines.append(f"    service: {yaml_escape(row['service'] or '')}")
    manifest_lines.append(f"    vault_namespace: {yaml_escape(row['vault_namespace'])}")
    manifest_lines.append(f"    vault_key: {yaml_escape(row['vault_key'])}")
    manifest_lines.append(
        f"    original_value_preview: {yaml_escape(row['original_value'][:40])}"
    )
    manifest_lines.append("")

manifest_yaml = "\n".join(manifest_lines)

if dry_run:
    print("=== patched compose (dry-run) ===")
    print(patched)
    print("=== vault manifest (dry-run) ===")
    print(manifest_yaml)
else:
    with open(out_compose, "w", encoding="utf-8") as f:
        f.write(patched)
    with open(out_manifest, "w", encoding="utf-8") as f:
        f.write(manifest_yaml)
    print(f"wrote: {out_compose}")
    print(f"wrote: {out_manifest}")
    print(f"found {len(manifest_rows)} credential-like env vars.")
PY
