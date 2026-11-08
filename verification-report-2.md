# Verification report 2 — independent check of the blocker fixes

Date: 2026-11-08. No source was changed. Throwaway env file and all docker
resources (project `verify2`: containers, volumes, network, built images) were
removed afterwards. Base images (postgres, caddy, maven, temurin) were left in
the local docker cache.

## Verdict
**No release blockers found.** Every claim (1)–(9) holds. Two low/minor
findings (docs/DX and SPA fallback), none of which affects production safety.

## Verified (with evidence)

| # | Claim | Result |
|---|---|---|
| 1 | `mvn clean test` green, ~109 tests | **109 run, 0 failures/errors/skipped, BUILD SUCCESS** (fresh `clean`). |
| 2 | Seeds moved; prod has no demo data | `db/dev-seed/` holds V2/V4/V16; `db/migration` has 13 files. Prod container: "Successfully validated 13 migrations"; `user_account` contains only the user I registered; login `diana@example.com`/`password123` → **401**. Dev profile on a fresh DB: "Successfully applied 16 migrations … v16", diana login → **200**, 16 rows in `flyway_schema_history`. |
| 3 | Startup refusal | Built prod image exits 1 with no env; without JWT_SECRET ("Could not resolve placeholder 'JWT_SECRET'"); without CORS_ALLOWED_ORIGINS; without DB_*; placeholder secret → "JWT_SECRET is the public placeholder value"; wildcard CORS → "no wildcard"; weak (5-byte) secret → WeakKeyException. `ProdConfigurationGuardTest` covers default-DB-password (see unverified). |
| 4 | Docs 404 in prod | Via Caddy: `/docs`, `/docs/index.html`, `/swagger-ui/index.html`, `/v3/api-docs` → 404. Directly on the backend (bypassing Caddy, from inside the network): `/docs` 404, `/v3/api-docs` 404, `/swagger-ui/index.html` 404 — so it is disabled in the app, not just at the edge. `/actuator/info`, `/actuator/env` → 401 (only `health` exposed). Dev profile still serves docs (302/200), as documented. |
| 5 | 400/404/405/415 | Authenticated, through proxy: malformed JSON → 400 "Malformed request body"; bad enum (`status: BOGUS`) → 400; unknown path → 404; wrong method → 405; `text/plain` body → 415; bad query param → 4xx (no 500). Unauthenticated unknown `/api/**` returns 401 (normal for secured routes). Covered by new `MalformedRequestIntegrationTest` too. |
| 6 | Stale tests fixed legitimately | Diffed against the backup copy. **ClientsIntegrationTest:** (a) the two assertions in `restaffingAClientDoesNotDisturbTheRestOfIt` previously compared against "Beauty"/"Наталія", values that appear nowhere in that test's payload (stale copy-paste) — now compare to the values the test actually posts ("Ніша", "Ігор Петренко"); the assertion is no stricter-or-looser, just correct; (b) `restaffingIsRefusedWithoutAClientsEditGrant` now explicitly lowers the member's CLIENTS grant to READ (the test's premise; SMM default is FULL) and still asserts 403 — product behaviour is *more* explicitly tested, not weakened; (c) `"stage":"BRIEF"` added to the payload because PUT requires it. **ContentPlanIntegrationTest:** the SMM now is staffed on the client (`saveClient(..., memberId)`) because SMM access is row-scoped (FR-08, `ClientVisibility`); the assertions on author name/id are unchanged. No assertions removed. |
| 7 | Compose/Dockerfiles/Caddyfile | `up -d --build` with a test `.env` (`SITE_ADDRESS=:80`): all 3 images built, postgres + backend `healthy`; `GET /actuator/health` through proxy → `{"status":"UP"}`; register → 200 with token, login → 200, authenticated `GET /api/v1/clients` → `[]`; `/` and a deep route `/clients/some/deep/route` → 200 (SPA fallback); CORS preflight from a foreign origin → 403, same-origin OK; only Caddy publishes host ports (80/443; postgres 5432 and backend 8080 are internal-only); backend runs as non-root; compose fails fast with a clear message when `JWT_SECRET` etc. are unset. Torn down with `down -v --rmi local`; no leftover containers/volumes/networks. |
| 8 | Frontend | `npm run lint`: 0 errors, 8 warnings (react-refresh); `npm test`: 34 files / 274 tests pass; `npm run build`: succeeds (500 kB chunk warning only). |
| 9 | README / secrets | Config table, prod section, migration notes, deployment paragraph match observed behaviour (except the item below). `.env.example` files (backend, frontend, deploy) contain only placeholders/empty values; `DB_PASSWORD=` and `JWT_SECRET=` blank in deploy example. Test `application.yml` secret is the well-known "change-me…" placeholder (the guard rejects it in prod). `frilance-backend/.env` is **git-ignored and untracked** (verified with `git ls-files`) and holds local dev values; frontend `.env.local` ignored too. No real secrets in tracked docs/config. The VITE_API_BASE_URL default `/api/v1` matches controllers' `/api/v1/**` prefix and Caddy's `handle /api/*`; no regression there. |

## Findings (ranked)

1. **Low — documented dev flow breaks with `.env.example`.** `frilance-backend/.env.example` has an empty `JWT_SECRET=` with the comment "Leave empty to use the dev profile's built-in default". Following the README/`.env.example` (`set -a; source .env`) exports `JWT_SECRET=""`, and Spring does *not* fall back to the `${JWT_SECRET:default}` when the variable exists but is empty. Reproduced: dev-profile container with `JWT_SECRET=` fails with `WeakKeyException … 0 bits`. Fix: comment the line out (`# JWT_SECRET=`) or fix the docs; optionally treat blank as unset in `application-dev.yml`. Not a prod issue.
2. **Minor — SPA fallback masks missing assets.** `/assets/nonexistent.js` returns 200 with `index.html` (Caddy `try_files {path} /index.html`). A stale browser after a deploy gets HTML for a JS chunk (MIME error) rather than a 404. Cosmetic/cache-behaviour; optionally restrict fallback to non-`/assets/` paths.
3. **Info — rate limiting / open registration.** README is honest that `/auth/register|login|claim-invite` have no rate limiting and the Caddyfile has none either (standard Caddy lacks the module). `register` is open on a public prod host; acceptable for a release only if intended.
4. **Info — backend image defaults to `prod` profile** and has no image-level healthcheck (documented; compose has one using `/dev/tcp`). Works.
5. **Info — `web` service has no healthcheck**; fine for now.

## Unverified / limits
- **Real HTTPS/ACME** with a public `SITE_ADDRESS` was not exercised (needs DNS + ports 80/443 reachable). Only `:80` plain HTTP was tested. The Caddyfile syntax is standard (`{$SITE_ADDRESS:localhost}`), and the compose file requires the variable, but the cert issuance path is untested. `CORS_ALLOWED_ORIGINS=https://<host>` must match the scheme actually served.
- **Default DB password rejection inside a container** was not demonstrable: with `DB_PASSWORD=frilanceos` the DB itself rejected the login first (the test DB had a different password). It is covered by `ProdConfigurationGuardTest.rejectsADefaultDatabasePassword` (passing) and by reading the guard source.
- **Upgrade path for existing DBs** that already applied V2/V4/V16 was not run; the README documents the Flyway "applied-but-missing" caveat accurately per code inspection only.
- Other uncommitted modifications in the backend repo (clients, content plan, finance code) pre-date the fixer and were not re-reviewed beyond passing tests.
- Browser UI against the prod stack was not driven; SPA index served and API proxied only.
