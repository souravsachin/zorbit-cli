# PM2 Catalogue — Test Fixture

Synthetic fixture for `scripts/pm2-catalogue.sh --fixture <this-dir>`.

Lets reviewers exercise the script's output formatting without bastion
access to a live VM. The data here mirrors the cycle-103 snapshot from
2026-04-26 (24 services in restart-loop) so the rendered table matches
the expected real-world shape.

## File layout

| File | Source it stands in for |
|---|---|
| `pm2-jlist__ze-core.json`  | `docker exec ze-core pm2 jlist` |
| `pm2-jlist__ze-pfs.json`   | `docker exec ze-pfs pm2 jlist` |
| `pm2-jlist__ze-apps.json`  | `docker exec ze-apps pm2 jlist` |
| `pm2-jlist__ze-ai.json`    | `docker exec ze-ai pm2 jlist` |
| `module-registry__modules.json` | `psql -d zorbit_module_registry -c 'SELECT json_agg(...) FROM modules'` |
| `health-probes.json`       | result map of `{uri: status_code}` for all `/api/<svc>/api/v1/G/health` curls |
| `zs-state__<container>.txt` | `docker inspect <container> --format '{{.State.Status}}...'` |

## Fixture sizes

Each `pm2-jlist__*.json` is a JSON array. We seed 4-5 services per
container to keep the file readable. The real environment has 66 PM2
processes; the fixture is representative not exhaustive.

## Refreshing the fixture from a real env

When bastion is back, owner can update the fixture by running:

```bash
ENV_PREFIX=ze
DEST=02_repos/zorbit-cli/scripts/fixtures/pm2-catalogue

ssh dev-sandbox "for c in ${ENV_PREFIX}-{core,pfs,apps,ai}; do
  docker exec \$c pm2 jlist > /tmp/pm2-jlist__\$c.json
done"
scp dev-sandbox:/tmp/pm2-jlist__*.json $DEST/

ssh dev-sandbox "docker exec zs-pg psql -U zorbit -d zorbit_module_registry -tAc \\
  \"SELECT json_agg(json_build_object('module_id', module_id, 'status', status::text)) FROM modules;\"" \
  > $DEST/module-registry__modules.json
```

Then re-run `bash scripts/pm2-catalogue.sh --env ze --fixture $DEST` and
diff the output against the live `--public-url` run.
