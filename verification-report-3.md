# Verification report 3: the two small fixes and the deploy checklist

Date: 2026-11-08. No source changed. Project `verify3` was torn down with `down -v --rmi local`. My throwaway Postgres container (`v3pg`) was stopped (it ran with `--rm`). Nothing is left behind. A pre-existing local Postgres on host port 5432 belongs to the user and was not touched.

## Verdict
**No release blockers.** Both findings from report 2 are fixed. The checklist and smoke test are correct as far as I could exercise them locally. A few gaps would bite a first deploy; they are listed below, none fatal.

## Verified
| # | Check | Result |
|---|---|---|
| R2-1 | `.env.example`: `set -a; source .env.example` then dev profile | `JWT_SECRET` is now unset after sourcing. Backend started in 4.8 s on the dev profile against a fresh Postgres. `/actuator/health` returned UP and demo login `diana@example.com` returned 200. README line 44-45 matches the file. |
| R2-1b | Prod profile still refuses bad config | Prod profile with `.env.example` sourced (no JWT) fails with "Could not resolve placeholder 'JWT_SECRET'". The placeholder, wildcard and default-DB-password refusals were not re-run here (see Unverified). |
| R2-2 | Caddy `/assets/*` | `/assets/nonexistent.js` and `.css` return 404 (also on HEAD). Real assets return 200: `.js` as `text/javascript; charset=utf-8`, `.css` as `text/css`. `/` and `/clients/deep/route` return 200 `text/html`. `/api/v1/clients` returns 401 via the proxy. `/actuator/health` returns 200 JSON. `/docs` and `/v3/api-docs` return 404. |
| 3a | `smoke-test.sh` | Against the local stack: 13/13 PASS, "ALL OK", exit 0. Against `http://localhost:9` it exits 1 with FAIL lines. With a wrong path it exits 1. With no argument it exits 1 (usage). `bash -n` passes. The file is executable. |
| 3b | Checklist commands | Ran the section 9 `pg_dump -Fc` (22 KB, non-empty), createdb, `pg_restore --no-owner` and count query (returned 1), and dropdb. All work. `compose config` passes with a real env. With the shipped `.env.example` it fails fast with "set DB_PASSWORD in .env". Env var names, ports 80/443, paths (`../../frilance-*`), service names and the `--env-file` usage match `docker-compose.prod.yml`. |
| 3c | Secrets | No real secrets in the checklist, smoke test, or the three `.env.example` files. |
| 4 | Tests | `mvn clean test`: 109 run, 0 failures, 0 errors, 0 skipped (from the surefire reports). Frontend: lint 0 errors / 8 warnings, 34 files / 274 tests pass, build OK. |
| 2 | Stack | `up -d --build` built all 3 images. postgres and backend were healthy. |

## Findings, ranked (none blocking)
1. **Medium: no HSTS or security headers anywhere.** The Caddyfile has no `header` directive, and Caddy does not add HSTS by default. The checklist (section 8 manual extras) greps for `strict-transport` and its "Known unverified" list mentions HSTS as if it exists. It will find nothing. Either add a `header { Strict-Transport-Security ... }` block (plus nosniff, frame-ancestors/X-Frame-Options, Referrer-Policy) or reword the checklist.
2. **Low: the smoke test's `/actuator/env not exposed` check is weak.** Through Caddy, `/actuator/env` returns 200 with `index.html` (the SPA fallback). The check passes only because the body lacks `activeProfiles` and `propertySources`. Safe, but a 404 would be cleaner. The same applies to `/actuator/*`, `/api` (no slash) and so on. It is not a leak.
3. **Low: the CORS and HTTPS checks can't be validated locally.** The smoke test's CORS check (403 for a foreign origin) passes, but nothing checks that `https://SITE_ADDRESS` is *allowed*. A wrong scheme or host in `CORS_ALLOWED_ORIGINS` would break same-origin POSTs in the browser only if the browser sends an `Origin` header. Chrome does for POST/PUT/DELETE, and Spring then returns 403. Add a smoke check: preflight with `Origin: $BASE` should return 200.
4. **Low: the smoke test leaves a `smoke-*@example.com` user in prod each run.** The checklist says so. There is no cleanup path, but there is no delete-account feature either.
5. **Info: `down -v` warning.** The checklist warns about it, and I confirmed `down -v` really deletes `pgdata`.

## Omissions that could bite a first deploy
- **Repo access.** Step 5 clones from GitHub. If the repos are private, the server needs a deploy key or token; the checklist says nothing about it. `freelance-all/deploy` is not in either repo, so it must be copied by hand (stated), and `smoke-test.sh` must keep its executable bit (`chmod +x` after rsync/scp).
- **Backups omit `caddy_data`.** Losing it means re-issuing certificates, which risks Let's Encrypt rate limits if done repeatedly. Low risk.
- **No swap on the VPS.** The Maven build of the backend plus npm on 4 GB can OOM. Consider 2 GB of swap, or build on the laptop and push images.
- **Docker log/disk growth.** Image layers accumulate; the checklist does mention `docker image prune`.
- **Cron uses `~/backup.sh` and `/home/deploy`.** This is fine only if the user is literally `deploy`. A mismatch silently produces no backups. Check `backup.log` after the first night.
- **Restore-to-live on `pg_restore` into an already-migrated DB.** The checklist correctly says to drop and recreate first.
- **Timezone/time sync.** JWT expiry depends on the clock. Ubuntu runs timesyncd by default, so it is fine.
- **No external alert for disk full / container down beyond the uptime check.** Acceptable for a closed test.

## Unverified
- Real HTTPS/ACME, the HTTP to HTTPS redirect (308), and a valid-cert `https://` CORS match. Only `:80` was run.
- The prod refusals for placeholder `JWT_SECRET`, wildcard CORS and the default DB password were not re-run here. My attempt used a dev-seeded database, so Flyway failed first (applied-but-missing V2/V4/V16), which proves nothing about the guards. They are covered by report 2 and `ProdConfigurationGuardTest` (passing in the 109).
- `shellcheck` is not installed. I reviewed `smoke-test.sh` and the `backup.sh` heredoc by eye and with `bash -n`. No issues except the points above: `set -u` without `-e` is intentional, variables are quoted, and the sed token extraction is fragile if the JSON key order changes but works today.
- The server hardening (ssh, ufw, unattended-upgrades), Docker install, cron backups, and rollback procedure were not run. A rollback with a migration was not rehearsed.
- Browser UI against the prod stack was not driven.
- Existing uncommitted changes in the repos were not reviewed beyond passing tests.
