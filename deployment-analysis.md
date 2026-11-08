# Frilance OS — deployment analysis for end-user testing

Read-only analysis, nothing deployed or changed. Date: 2026-11-08. Prices are rough, from memory, and must be re-checked on the provider's page before committing.

## 1. What has to be deployed

| Piece | What it is | Notes |
|---|---|---|
| Backend | Spring Boot 3.3.4, Java 21, Maven, one fat jar (`spring-boot-maven-plugin`) | Port from `PORT` (default 8080). Flyway runs on start, `ddl-auto: validate`. Health: `/actuator/health` (public, only `health` exposed). |
| Frontend | Vite + React 18 + react-router (BrowserRouter-style SPA), `npm run build` → `dist/` | Static files only. **Needs an SPA fallback** (unknown path → `index.html`), otherwise a refresh on `/clients` is a 404. |
| Postgres | 16 | Flyway creates the schema (V1–V16). No extensions or special features noticed. |

There are no other moving parts: no Redis, queue, object storage, email/SMTP or outbound third-party calls were found, and the backend runs no scheduled jobs. Invite tokens are shown in the UI rather than emailed, as far as I can tell. That keeps the infra small.

### Config and secrets

Backend (environment variables, all read from `application.yml`):

| Var | Default in repo | Prod requirement |
|---|---|---|
| `DB_URL` | `jdbc:postgresql://localhost:5432/frilanceos` | set (JDBC form, with `?sslmode=require` if the DB is remote/managed) |
| `DB_USERNAME` / `DB_PASSWORD` | `frilanceos` / `frilanceos` | **must be overridden** with a strong password |
| `JWT_SECRET` | a base64 placeholder that decodes to "change-me-to-a-real-base64-secret…" | **must be overridden**: `openssl rand -base64 48`. `JwtService` base64-decodes it. Anyone who knows the default can forge tokens for any tenant. |
| `JWT_ACCESS_TOKEN_TTL_MINUTES` | 1440 | fine for testing |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:5173` | comma-separated list, exact origin(s) of the frontend, e.g. `https://app.example.com`. Not needed at all if frontend and API are served from the same origin (see recommendation). |
| `PORT` | 8080 | |
| `SPRING_PROFILES_ACTIVE` | unset | There is no `application-prod.yml`; only `application-dev.yml` (DEBUG logging, SQL logging). Leaving the profile unset is already the "non-dev" mode, so a prod profile is optional. Set it to something harmless, or add a small `application-prod.yml` later. |

Frontend (build-time only, baked into the bundle by Vite):

| Var | Value |
|---|---|
| `VITE_API_BASE_URL` | e.g. `https://app.example.com/api/v1` (same-origin) or `https://api.example.com/api/v1`. `src/api/client.ts` reads it with no fallback, so if it is missing at build time the app breaks. `.env.local` is git-ignored (`*.local`), so CI/hosting must supply it. |

The token is stored in `localStorage` and sent as a Bearer header, so there are no cookies and no CSRF concerns. CORS only needs `Authorization` and `Content-Type`, which the backend already allows.

## 2. Findings in the code (risks / blockers)

Ordered by importance.

1. **Demo accounts with a known password ship inside Flyway migrations.** `V2`, `V4` and `V16` are versioned migrations, so they run on every database, including prod. They create `diana@example.com` (an OWNER) plus Аліна, Оксана, Наталя and Іван `@example.com`, all with the bcrypt hash of `password123`. They are tenant-isolated, so they cannot read a real user's data, but they are publicly documented logins (README) and they put sample clients, posts and finance rows into a fresh DB. A stranger who logs in as the demo owner can also invite members, so this is real attack surface. Without a code change you can't skip them cleanly: later migrations (V3, V5, V16 and others) assume those rows exist, and CLAUDE.md warns about V16 keying on seeded data. **For the test, run them and then neutralise the demo users right after the first start**: either delete the five users and their tenant data, or `UPDATE user_account SET password_hash = <random bcrypt>`. A proper fix is a follow-up: move seeds to a separate Flyway location (for example `db/seed`) that only the dev profile adds to `spring.flyway.locations`. That changes migration history, so it is best done before the first prod DB exists.
2. **Secret and DB defaults are insecure but fail open.** `JWT_SECRET` and the DB password have working defaults, so a forgotten env var starts the app happily with a publicly known signing key. For prod, treat a missing `JWT_SECRET` as a deploy failure: the checklist below sets them explicitly and verifies them. A follow-up is to drop the default outside tests.
3. **Open self-registration.** `POST /api/v1/auth/register` is public, and no rate limiting or lockout was found anywhere (no bucket4j or similar dependency, no filter). Login timing is hardened (decoy bcrypt) but brute force and signup spam are not throttled. For a small test audience this is acceptable; mitigate with an obscure URL, Caddy/Cloudflare rate limits on `/api/v1/auth/*`, and later a code-level limiter or an invite-only flag.
4. **Swagger UI at `/docs` and `/v3/api-docs` are public** (permitAll). Harmless for data, but it advertises the API. Block those paths in the reverse proxy for prod.
5. **Single 24 h access token, no refresh, no revocation.** CLAUDE.md itself says "acceptable for local/demo use, not for anything real". Fine for a closed test. Don't market it as production.
6. **No Dockerfile, no CI config, no prod compose.** `docker-compose.yml` only runs Postgres with `frilanceos/frilanceos` credentials and publishes 5432 to the host. **Never reuse that file on a server as-is** (public DB port + default password).
7. **Both repos have uncommitted work.** The backend's `git status` shows many modified files (clients module, `pom.xml`, `CLAUDE.md`, …). A deploy should come from a committed, pushed state, so commit or tag first. Remotes exist on GitHub: `dianabirkovic-gif/frilance-backend` and `…/frilance-frontend`.
8. **The backend has never been verified to build in this environment.** No JDK is installed on this machine (`java -version` fails), and the README says the project was scaffolded without ever being compiled. The tests need Docker for Testcontainers. A Docker multi-stage build (below) avoids needing local Java, and it doubles as the first full build check. Expect to fix small things on the first try.
9. **Data residency / compliance.** Users are Ukrainian freelancers, and the data holds client names, phones, emails and finance entries (personal data of third parties). Hosting in the EU is the natural choice (GDPR-aligned, low latency). Ukrainian law doesn't generally require in-country storage for this kind of app. For a closed test this is fine, but state the data location in the test-participant notice.
10. **Hibernate `format_sql: true`** is in the base config. It is harmless, but SQL logging only turns on in the dev profile, so don't activate `dev` in prod.
11. **Minor:** `management.endpoints.web.exposure.include: health` is good. Show-details is off, so the health response is just `UP`/`DOWN`. The JVM defaults will want a memory cap on a small box (`-XX:MaxRAMPercentage=70`).

## 3. Hosting options

Latency note: Kyiv ↔ Frankfurt/Falkenstein/Helsinki is roughly 35–60 ms, which is fine for a CRUD app. A US region would add ~150 ms per call and should be avoided.

### Option A — Single EU VPS: Docker Compose + Caddy (backend jar + Postgres + static frontend)
- **Cost:** about €4–8/month (Hetzner CX22-class: 2 vCPU / 4 GB, Falkenstein or Helsinki; DigitalOcean/Vultr in Frankfurt are ~$6–12). Domain ~€10–15/year. Optional Hetzner backups +20% of the server price.
- **Setup effort:** medium, about 2–4 hours the first time (server hardening, Docker, Caddyfile, DNS).
- **Pros:** cheapest, one bill, everything in one EU location, no cold starts and no free-tier sleep, full control of the DB (no 0.5 GB/connection limits), Caddy gives automatic HTTPS and serves the SPA with fallback and `/api` proxying on one origin (no CORS, no `VITE_API_BASE_URL` cross-origin issues).
- **Cons:** you own patching, backups, monitoring and security. Single point of failure, no autoscaling. Needs basic Linux comfort.

### Option B — Render (backend Docker web service + Render Postgres) + Cloudflare Pages / Vercel / Netlify (frontend)
- **Cost:** Render web service Starter ~$7/month (the free tier sleeps and has slow cold starts, which are bad for a JVM app). Render Postgres paid tier ~$6–7/month (the free DB is deleted after a limited period). Static host: free. Total ≈ $14/month.
- **Setup effort:** low, about 1–2 hours, mostly UI clicks plus a Dockerfile.
- **Pros:** push-to-deploy, managed TLS, managed Postgres with backups on paid plans, no server upkeep. Frankfurt region available.
- **Cons:** costs about 2–3× Option A for less resource; a cross-origin setup means CORS must be right; Spring Boot on 512 MB is tight; two or three dashboards to juggle.

### Option C — Fly.io (backend + Fly Postgres or Neon) + Cloudflare Pages (frontend)
- **Cost:** roughly $5–15/month depending on VM size (a shared-cpu 512 MB–1 GB machine for the JVM) plus the DB (Fly's own Postgres is unmanaged; Neon free/Launch tier is managed).
- **Setup effort:** medium: CLI-driven (`flyctl`), Dockerfile required, volumes and secrets by CLI.
- **Pros:** EU regions (Frankfurt/Amsterdam/Warsaw), machines can auto-stop to save money, secrets handled well.
- **Cons:** more moving parts than Render; unmanaged Fly Postgres means backups are on you; billing is usage-based and easy to misread. Neon adds a cross-provider hop and cold-start latency on its free tier.

### Option D — Railway (backend + Postgres plugin) + Vercel/Netlify (frontend)
- **Cost:** usage-based, typically ~$5–15/month for this footprint after the trial credit.
- **Setup effort:** low, about 1 hour.
- **Pros:** the nicest developer experience, Postgres in one click, detects a Dockerfile or Maven build.
- **Cons:** EU region choice and backup guarantees are weaker; usage pricing is unpredictable; the DB is not a hardened managed service. Fine for a throwaway, less so for data users will care about.

(Supabase/Neon as the DB with a PaaS app is possible with any of B–D; it adds a network hop and connection-pool considerations with no benefit at this size, so I'd skip it.)

### Comparison at a glance

| | Cost/mo | Effort | Ops burden | CORS issues | Fits "test, then maybe grow" |
|---|---|---|---|---|---|
| A VPS + Caddy | ~€5–8 | medium | you | none (same origin) | yes, easy to move later |
| B Render + CF Pages | ~$14 | low | low | yes | yes |
| C Fly + CF Pages | ~$8–15 | medium | medium | yes | yes |
| D Railway + Vercel | ~$5–15 | low | low | yes | okay |

## 4. Recommendation: Option A (EU VPS, Docker Compose, Caddy, same-origin)

Why: the cheapest, fastest for Ukrainian users, no CORS surface, and the whole stack is one `docker compose up`. The app is a single JVM plus Postgres, which is exactly what one small VM handles for a test audience of tens of users. If the owner would rather pay ~$14/month for zero server upkeep, Option B is the fallback; the same Dockerfile works for it.

### Files that need to be created (not created by this analysis)

**`frilance-backend/Dockerfile`**
```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q -DskipTests package

FROM eclipse-temurin:21-jre
WORKDIR /app
RUN useradd -r -u 1001 app
COPY --from=build /app/target/*.jar app.jar
USER app
EXPOSE 8080
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=70"
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
  CMD wget -qO- http://localhost:8080/actuator/health | grep -q UP || exit 1
ENTRYPOINT ["java","-jar","app.jar"]
```
(The JRE image may lack `wget`/`curl`; if so, do the health check in compose with a tiny `bash`-less alternative or from Caddy/uptime monitor instead. Also add `.dockerignore` with `target/`, `.env`, `.git`.) `-DskipTests` is because the tests need Docker-in-Docker; run `mvn verify` locally or in CI instead.

**`frilance-frontend/Dockerfile`** (multi-stage build, output copied to the Caddy image or a volume)
```dockerfile
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ARG VITE_API_BASE_URL
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
RUN npm run build

FROM caddy:2-alpine
COPY --from=build /app/dist /srv
COPY Caddyfile /etc/caddy/Caddyfile
```
Alternatively build `dist/` on the laptop/CI and `rsync` it, which is simpler for a test.

**`Caddyfile`** (single domain, same origin)
```
app.example.com {
    encode gzip zstd
    @blocked path /docs* /swagger-ui* /v3/api-docs*
    respond @blocked 404
    handle /api/* {
        reverse_proxy backend:8080
    }
    handle {
        root * /srv
        try_files {path} /index.html
        file_server
    }
}
```
With this layout, build the frontend with `VITE_API_BASE_URL=/api/v1` (a relative path works as long as `client.ts` just concatenates; confirm before relying on it) or the full `https://app.example.com/api/v1`, and `CORS_ALLOWED_ORIGINS=https://app.example.com` as a belt-and-braces setting. Rate limiting on `/api/v1/auth/*` needs the Caddy `rate_limit` plugin (not in the stock image) or Cloudflare in front; a simple alternative is Cloudflare's free rate-limiting rule if the domain's DNS is on Cloudflare.

**`docker-compose.prod.yml`** (on the server, not published DB port)
```yaml
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: frilanceos
      POSTGRES_USER: frilanceos
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U frilanceos"]
      interval: 10s
  backend:
    build: ./frilance-backend
    restart: unless-stopped
    depends_on: { postgres: { condition: service_healthy } }
    environment:
      DB_URL: jdbc:postgresql://postgres:5432/frilanceos
      DB_USERNAME: frilanceos
      DB_PASSWORD: ${DB_PASSWORD}
      JWT_SECRET: ${JWT_SECRET}
      CORS_ALLOWED_ORIGINS: https://app.example.com
  web:
    build: { context: ./frilance-frontend, args: { VITE_API_BASE_URL: https://app.example.com/api/v1 } }
    restart: unless-stopped
    ports: ["80:80","443:443"]
    volumes: [caddy_data:/data, caddy_config:/config]
    depends_on: [backend]
volumes: { pgdata: {}, caddy_data: {}, caddy_config: {} }
```
No `ports:` on postgres or backend: only Caddy is public.

### Deploy checklist

1. **Before anything:** commit and push both repos (backend has uncommitted changes). Tag the release. Run `mvn verify` somewhere with JDK 21 + Docker, plus `npm run build && npm test` in the frontend; a first Docker build is the only build proof so far.
2. Add the Dockerfiles, `.dockerignore`, `Caddyfile` and prod compose file above (in a small commit or a separate `deploy/` folder).
3. Buy/pick a domain; create DNS `A` record `app.<domain>` → server IP (and `AAAA` if IPv6). Optionally put it behind Cloudflare (proxied) for rate limiting and DDoS cover.
4. Provision a VPS in an EU region (Falkenstein/Helsinki/Frankfurt), Ubuntu LTS, ≥2 GB RAM (4 GB comfortable for JVM + Postgres + a Maven/Node build on the box; or build images elsewhere and push to a registry to use 2 GB). Create a non-root sudo user, SSH key only, disable password login, enable `ufw` (22, 80, 443 only) and unattended-upgrades. Install Docker + compose plugin.
5. Create `.env` next to the compose file (`chmod 600`, never commit): `DB_PASSWORD=$(openssl rand -base64 24)`, `JWT_SECRET=$(openssl rand -base64 48)`. Keep a copy in the owner's password manager.
6. `docker compose -f docker-compose.prod.yml up -d --build`. Watch backend logs for Flyway applying V1–V16 and Hibernate validate passing.
7. **Neutralise the demo users immediately** (finding 1): delete or re-password `diana@example.com` and the four `@example.com` team logins, then confirm `POST /api/v1/auth/login` with `password123` returns 401.
8. Smoke test: `curl https://app.<domain>/actuator/health` → `{"status":"UP"}` (proxy `/actuator/health` too, or hit it inside the network), open the site, register a fresh account, create a client and a post, reload on a deep link (SPA fallback), confirm `/docs` returns 404, confirm the TLS cert is valid. Check from a Ukrainian network/phone.
9. **Backups:** nightly `pg_dump` via cron on the host, e.g. `docker compose exec -T postgres pg_dump -U frilanceos -Fc frilanceos > /backups/frilanceos-$(date +%F).dump`, keep 7–14 days, and copy off the box (rclone to Backblaze B2/S3, or at least `scp` home). Add the provider's snapshot backups (about +20%). **Do one test restore** into a scratch DB before inviting users. Never run `docker compose down -v` on this host.
10. **Monitoring:** a free UptimeRobot/Better Stack check on the health URL with an email/Telegram alert. `docker compose logs -f` for debugging; set Docker log rotation (`max-size: 10m`, `max-file: 3`) to avoid filling the disk.
11. **Updates:** `git pull && docker compose -f docker-compose.prod.yml up -d --build`. Remember Flyway migrations are one-way: never edit an applied migration (CLAUDE.md), and take a `pg_dump` before any deploy that includes a new migration.
12. Tell testers plainly: this is a test environment, data may be reset, the app has no password reset or refresh tokens yet, and where the data is hosted.

### Follow-ups worth doing before a wider audience (not blockers for a closed test)
- Move seed migrations to a dev-only Flyway location.
- Remove the `JWT_SECRET` and DB password defaults outside test and dev.
- Rate-limit `/auth/register`, `/auth/login` and `/auth/claim-invite` in code.
- Add GitHub Actions: `mvn verify` (Testcontainers works on GH runners), `npm test && npm run build`, optionally image push + SSH deploy.
- Refresh tokens / shorter access TTL, password reset (no email infra exists yet).
- Consider Postgres Row-Level Security (already flagged in CLAUDE.md) before real customer data.

## Summary

Deploy three things: the Spring Boot jar, Postgres 16, and the static Vite build. Required secrets are `JWT_SECRET`, `DB_PASSWORD` (plus `DB_URL`/`DB_USERNAME`) and `CORS_ALLOWED_ORIGINS`. `VITE_API_BASE_URL` has to be set at frontend build time. Recommended: one EU VPS (~€5–8/month) running Docker Compose with Caddy, serving the SPA and proxying `/api` on one origin with automatic HTTPS, nightly `pg_dump` to off-box storage. Main risks found: the Flyway seed migrations create demo logins (`diana@example.com` and four teammates, all `password123`) in any database, so they must be removed or re-passworded right after the first start. The `JWT_SECRET` and DB password defaults fail open, registration and login have no rate limiting, `/docs` is public, and there is no Dockerfile or prod compose. Both repos have uncommitted work, and the backend has never been built in this environment (no local JDK).
