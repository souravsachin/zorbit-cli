# PM2 Service Catalogue — ze

Generated: 2026-04-26T03:23:23+07:00
Source: fixture (scripts/fixtures/pm2-catalogue)

## ze-* PM2 services

| Service | Container | Module manifest | Uptime | PM2 status | Restarts | Internal port | Public nginx URI | Health |
|---|---|---|---|---|---:|---:|---|---:|
| zorbit-cor-identity | ze-core | READY | 2h 23m | online | 3 | 3001 | `/api/identity/` | 200 OK |
| zorbit-cor-authorization | ze-core | READY | 2h 21m | online | 5 | 3002 | `/api/authorization/` | 200 OK |
| zorbit-cor-navigation | ze-core | READY | 2h 23m | online | 0 | 3003 | `/api/navigation/` | 200 OK |
| zorbit-event_bus | ze-core | READY | — | waiting restart | 99 | 3004 | `/api/event_bus/` | 502 BAD-GW |
| zorbit-pii-vault | ze-core | PENDING | — | waiting restart | 99 | 3005 | `/api/pii-vault/` | 502 BAD-GW |
| zorbit-cor-module_registry | ze-core | READY | — | waiting restart | 72 | 3020 | `/api/module_registry/` | 502 BAD-GW |
| zorbit-cor-deployment_registry | ze-core | READY | 2h 25m | online | 0 | 3022 | `/api/deployment_registry/` | 200 OK |
| zorbit-pfs-datatable | ze-pfs | READY | 2h 23m | online | 2 | 3013 | `/api/pfs-datatable/` | 200 OK |
| zorbit-pfs-form_builder | ze-pfs | PENDING | — | waiting restart | 391 | 3014 | `/api/pfs-form_builder/` | 502 BAD-GW |
| zorbit-pfs-integration | ze-pfs | READY | — | waiting restart | 391 | 3115 | `/api/pfs-integration/` | 502 BAD-GW |
| zorbit-pfs-file_viewer | ze-pfs | READY | — | waiting restart | 386 | 3116 | `/api/pfs-file_viewer/` | 502 BAD-GW |
| zorbit-pfs-workflow_engine | ze-pfs | READY | — | waiting restart | 386 | 3117 | `/api/pfs-workflow_engine/` | 502 BAD-GW |
| zorbit-app-broker | ze-apps | READY | 2h 21m | online | 0 | 3201 | `/api/app-broker/` | 200 OK |
| zorbit-app-sample | ze-apps | READY | — | waiting restart | 390 | 3210 | `/api/app-sample/` | 502 BAD-GW |
| zorbit-app-zmb_selftest | ze-apps | READY | — | waiting restart | 378 | 3211 | `/api/app-zmb_selftest/` | 502 BAD-GW |
| zorbit-app-hi_quotation | ze-apps | READY | — | waiting restart | 378 | 3220 | `/api/app-hi_quotation/` | 502 BAD-GW |
| zorbit-ai-tele_uw | ze-ai | READY | 2h 13m | online | 6 | 3600 | `/api/ai-tele_uw/` | 200 OK |

**Summary:** total=17 · online=7 · errored=0 · restart-loop=10

## zs-* shared infra

| Container | Status |
|---|---|
| zs-pg | running (healthy) |
| zs-mongo | running (healthy) |
| zs-kafka | running (healthy) |
| zs-redis | running (healthy) |
| zs-nginx | running (unhealthy) |

## Notes

- restart_count > 50 → Section H.5 fail (per test-plan-v3 §H)
- Health probed via `fixture/api/<svc>/api/v1/G/health`
- Manifest status `MISSING` = PM2 has the process but module_registry doesn't — registry-drift finding
