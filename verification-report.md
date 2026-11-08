# Verification report — Frilance OS readiness for end-user testing (2026-11-08)

Source code was not changed. Smoke test used a throwaway DB (`verify_smoke`, dropped afterwards); the existing `frilanceos` DB was not touched.

## Verdict
**Not ready to hand to outside testers as-is.** Functionally the app works end to end, but there is one high-severity release blocker (seeded demo accounts with a known password ship in the migrations) and the backend test suite is red (5 failing integration tests, all stale tests, not product bugs).

## Verified
| Check | Result |
|---|---|
| Frontend `npm run lint` | 0 errors, 8 warnings (all react-refresh/only-export-components) |
| Frontend `npm test` | 34 files, 274 tests pass |
| Frontend `npm run build` | OK (one bundle 804 kB / 252 kB gzip; chunk-size warning only) |
| Docker | Was installed but daemon not running; started Docker Desktop (still running — quit it if unwanted) |
| Backend `mvn test` with Docker | 102 run, 97 pass, **5 fail** (see below). Integration tests were never green before — they had only been unrunnable |
| Flyway V1–V16 on an empty Postgres | All 16 applied; Hibernate `ddl-auto: validate` passed; app started in ~5 s with `dev` profile |
| API smoke (curl, dev profile, port 8099) | register FREELANCER → 200 + JWT; `/auth/me` → access all FULL; create client → 200; create post → 200 (author set); create finance entry (INCOME, CARD, PAID) → 200; content-plan, finance and dashboard reads reflect them (dashboard revenue 1500.50); no token → 401; CORS preflight allows `http://localhost:5173`, rejects `http://evil.com` (403); `/actuator/health` UP |

## Unverified
- **Frontend UI against the live backend** (login, forms, drawers) — not driven in a browser. Vite dev server served 200 but `.env.local` points to :8080; I did not exercise screens.
- Agency flows by API (invite, claim-invite, member access) — covered only by the integration tests, which include the failures below.
- Production-profile behaviour: there is no `prod` profile, no production deployment was tried, no HTTPS/proxy config.

## The 5 failing integration tests (all look like stale tests, not product defects)
I read each failure against the service code:
1. `ClientsIntegrationTest.removingAMemberFromAClientTakesTheirSightOfItAway` — test's PUT `/clients/{id}` payload omits required `stage` (`@NotNull`) → 400, so staffing never changes.
2. `ClientsIntegrationTest.restaffingAClientDoesNotDisturbTheRestOfIt` — asserts niche `"Beauty"`, but the helper payload creates `"Ніша"`.
3. `ClientsIntegrationTest.restaffingIsRefusedWithoutAClientsEditGrant` — comment says "saveMember grants nothing", but the constructor applies `RoleAccessPolicy.defaultAccessFor(SMM)` = CLIENTS FULL, so 200 is the designed behaviour.
4. `ContentPlanIntegrationTest.authorIsTheMemberWhoCreatedThePostNotTheTenantOwner` and 5. `editingAPostLeavesItsAuthorAlone` — an SMM creates a post for a client with no assignees; SMM is row-scoped so the client is invisible → create fails (`created.id()` null → "Invalid UUID string: null" in log). Fixtures need the member assigned (and test name "Тестова Учасниця" asserted).
Not independently re-run after fixes; these should be fixed so the suite is green before any release.

## Release blockers, ranked
1. **HIGH — Demo accounts seeded by Flyway in every environment.** `V2__seed_dashboard_demo_data.sql` (plus V4, V16) inserts `diana@example.com` (OWNER) and 4 team members with BCrypt of `password123` and demo clients/finance data. Confirmed: after migrating a clean DB, `POST /auth/login diana@example.com/password123` → 200. Anyone who knows the README can log in to a tester deployment, and real testers will see demo data mixed with their view only if they share a tenant (they don't, since scoping works), but the accounts themselves are a credential risk. Move seeds to the `dev` profile/Flyway location or a separate `db/dev` folder.
2. **HIGH (config) — Default JWT secret is a public constant.** `application.yml` falls back to a base64 "change-me…" value, so forgetting `JWT_SECRET` in deployment silently allows forged tokens (any role/tenant). Fail startup unless set outside dev/test. Likewise DB defaults `frilanceos/frilanceos` and CORS default localhost:5173 (must be set for the real frontend origin).
3. **MEDIUM — Swagger UI and `/v3/api-docs` are unauthenticated** (`SecurityConfig` permitAll; `/docs` → 302, api-docs 200). Fine for dev; disable or protect for a public deployment.
4. **MEDIUM — Red test suite** (5 stale integration tests, above). A CI gate would fail.
5. **MEDIUM — Malformed request enums return 500** (`HttpMessageNotReadableException`, e.g. an invalid `stage`) via `GlobalExceptionHandler` catch-all "Unhandled exception", should be 400. Noise in logs and bad UX on any client bug.
6. **LOW — README stale.** Says only FR-01 and the dashboard are implemented, documents `diana@example.com/password123` and `attention_item` (dropped in V5), "Testcontainers integration test" singular. No deployment/env var section beyond `JWT_SECRET`; `CORS_ALLOWED_ORIGINS`, `DB_*`, `PORT` are undocumented. See also `deployment-analysis.md`.
7. **LOW — Single 24 h access token, no refresh** (known simplification); future-dated finance entries appear in dashboard revenue series (cosmetic).
8. **LOW — `dev` profile** sets DEBUG + `org.hibernate.SQL` logging; base profile is INFO only (fine). `spring.jpa.properties.hibernate.format_sql: true` is on in base config (minor log noise).

## Scan results with nothing found
- No `TODO/FIXME/HACK` and no `console.log/debug` in frontend `src` or backend `src/main`.
- No hardcoded credentials in frontend; API base URL comes from `VITE_API_BASE_URL` (`.env.local` → `localhost:8080`; a production build needs this set at build time).
- Only `/actuator/health` is exposed; auth required on all other API routes (401 verified).

## `new-requirements.md` — unfinished items (documented, not blockers)
- #20: "Список" as posts sorted by status is not built (deemed unneeded).
- #26d: «Завантажити PDF» (FR-17, reports module) and «Надіслати нагадування» (no outbound notifications) are intentionally absent.
- No open checklist/TODO markers otherwise.

## Suggested next steps before inviting testers
1. Move demo seed migrations out of the default Flyway path (or guard them) — and re-verify V-numbering/checksums for any DB that already ran them.
2. Require `JWT_SECRET` (and DB credentials, CORS origin) when not in dev/test; lock down `/docs`.
3. Fix the 5 stale tests; rerun `mvn test` with Docker.
4. Drive the UI once in a browser against the backend (register → client → post → finance).
5. Update the README.
