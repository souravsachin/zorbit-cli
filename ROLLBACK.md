# Zorbit Bootstrap — Rollback Protocol

Version: 1.0 (2026-04-23)
Owner:   Zorbit platform team
Author:  Soldier BF

This document describes how `bootstrap-env.sh` records every state-changing
step and how those steps get reversed on failure.

---

## TL;DR

- Every state change appends one JSON line to an **install journal**.
- On any non-zero exit, an `EXIT` trap replays the journal **in reverse**.
- `bootstrap-env.sh --env <name> --rollback-last` replays manually.
- `--no-auto-rollback` keeps the partial install for manual forensics.
- Rollback is best-effort — individual undo failures log and continue.

---

## Journal location

```
/opt/zorbit-platform/<env>/install-journal.jsonl
```

On successful install the file is archived to
`install-journal.<timestamp>.jsonl` in the same directory so it never gets
replayed a second time.

## Journal entry schema

```json
{
  "ts":    "2026-04-23T14:02:11Z",
  "step":  "create_database",
  "env":   "zorbit-dev",
  "cmd":   "docker exec zs-pg psql -c 'CREATE DATABASE ...'",
  "undo":  "docker exec zs-pg psql -c 'DROP DATABASE ...'",
  "tags":  "database,postgres,dev",
  "status":"ok"
}
```

An entry with `undo == ""` is recorded but **treated as a no-op** during
replay. This is intentional for steps that can't be safely undone (e.g.
module-registry announce is TTL'd, nginx/systemd require sudo).

---

## Registered step types

Every one of these writes a journal entry. If you add a new state-changing
step to `bootstrap-env.sh` you MUST add a matching `journal_record` call.

| # | step key                 | has undo? | notes                                          |
|---|--------------------------|-----------|------------------------------------------------|
| 1 | preflight_dir            | no        | mkdir is idempotent                            |
| 2 | git_clone                | no        | leave source in place on rollback              |
| 3 | docker_pull_base         | yes       | `docker image rm zorbit-pm2-base:1.0`          |
| 4 | npm_build                | no        | build artefacts are disposable                 |
| 5 | docker_network_create    | yes       | `docker network rm <prefix>-net`               |
| 6 | compose_up_postgres      | yes       | `docker rm -f <prefix>-pg`                     |
| 7 | compose_up_mongo         | yes       | `docker rm -f <prefix>-mongo`                  |
| 8 | compose_up_kafka         | yes       | `docker rm -f <prefix>-kafka`                  |
| 9 | compose_up_redis         | yes       | `docker rm -f <prefix>-redis`                  |
|10 | database_create          | no        | undo deferred to `decommission.sh`             |
|11 | compose_generate         | yes       | `rm -f /tmp/docker-compose.<env>.yml`          |
|12 | module_registry_announce | no        | 30-min TTL; no explicit undo                   |
|13 | nginx_config_install     | yes       | `rm -f /tmp/<host>.nginx.conf` (sudo for /etc) |
|14 | certbot_ssl              | no        | shared wildcard cert — never delete            |
|15 | smoke_test_run           | no        | read-only                                      |
|16 | systemd_enable           | no        | requires sudo; decommission.sh prints cmds     |
|17 | caffeinate_enable        | yes       | `pkill -f 'caffeinate.*<env>'`                 |

---

## Auto-rollback trap

`bootstrap-env.sh` registers the trap right after the env name is resolved:

```bash
journal_init "${ENV_NAME}"
trap 'journal_rollback_auto_trap "${ENV_NAME}" $?' EXIT
```

The handler:

1. If exit code is 0 — do nothing.
2. If `ZORBIT_SKIP_AUTO_ROLLBACK=true` (set by `--no-auto-rollback`) — log a
   warning and leave the journal in place.
3. Otherwise — call `journal_rollback` which replays every undo in LIFO
   order, logging failures but continuing.

On successful completion the script clears the trap (`trap - EXIT`) and
archives the journal.

---

## Manual rollback invocation

```bash
./scripts/bootstrap-env.sh --env dev --rollback-last
```

Flow:

1. Resolves env name, prints the journal path.
2. Calls `journal_list_undos` to show a numbered LIFO preview.
3. Prompts `?` unless `--yes` is passed.
4. Calls `journal_rollback` — executes every undo in reverse.
5. On success, archives the journal (so it won't replay again).

With `--dry-run` no undos run but the plan is printed:

```bash
./scripts/bootstrap-env.sh --env dev --rollback-last --dry-run
```

---

## Best-effort semantics

Rollback is explicitly **best-effort**:

- A failing undo logs a warning and continues.
- Final report prints `N entries, M failures`.
- Exit code is `4` if any undo failed, `0` if all succeeded.

**Rationale**: a partial install that also has partial rollback is still
better than one where the rollback itself aborted and left zombie
containers plus leaked state.

---

## What rollback does NOT handle

| Case                  | Why not                          | Mitigation                       |
|-----------------------|----------------------------------|----------------------------------|
| nginx /etc cleanup    | requires sudo                    | `decommission.sh` prints cmds    |
| systemd /etc cleanup  | requires sudo                    | `decommission.sh` prints cmds    |
| per-service DBs       | data may matter                  | `decommission.sh --keep-data`    |
| wildcard SSL certs    | shared across envs               | never auto-remove                |
| module-registry state | event-sourced, 30-min TTL        | will expire naturally            |

For any of the above use `decommission.sh` with the appropriate flags.

---

## Debugging

- View the journal: `cat /opt/zorbit-platform/<env>/install-journal.jsonl`
- Count entries:    `wc -l /opt/zorbit-platform/<env>/install-journal.jsonl`
- Preview replay:   `bootstrap-env.sh --env <env> --rollback-last --dry-run`
- Force keep on fail: `bootstrap-env.sh --env <env> --no-auto-rollback`

---

## Related tooling

| Script            | Purpose                                                   |
|-------------------|-----------------------------------------------------------|
| bootstrap-env.sh  | Install + auto-rollback + --rollback-last                 |
| decommission.sh   | Uninstall an env cleanly (discovery + confirm + remove)   |
| smoke-test.sh     | Post-install verification (health / manifest / identity)  |
| promote-env.sh    | Tier promotion (dev -> qa -> demo -> uat -> prod)         |

---

*End of ROLLBACK.md*
