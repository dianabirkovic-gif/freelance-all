# Frilance OS — deploy checklist (single EU VPS + Docker Compose + Caddy)

Target: one small EU VPS (e.g. Hetzner CX22-class, Falkenstein/Helsinki, ~€5–8/mo)
running `docker-compose.prod.yml`: Caddy (HTTPS, SPA, `/api` proxy) → backend → Postgres.
Same origin, no CORS surface. Background: `../deployment-analysis.md`.

Nothing in this file has been executed against a real server. Commands marked
*(verified locally)* were run against the stack on `localhost` with `SITE_ADDRESS=:80`.

---

## 0. Before you touch a server

- [ ] Backend and frontend work is **committed and pushed** (both repos currently have uncommitted changes). Deploy from a tag/commit you can name: `git rev-parse HEAD` in both repos, write it down.
- [ ] `mvn clean test` (Docker needed) and `npm run lint && npm test && npm run build` are green on that commit.
- [ ] You own a domain and can edit its DNS (e.g. `app.example.com`).
- [ ] Decide the open questions in the pre-invite checklist below (open registration, privacy notice).

## 1. Provision the server

- [ ] Create a VPS: Ubuntu 24.04 LTS, 2 vCPU / 4 GB RAM, **EU region**, SSH key auth only (no password login). Enable the provider's backup/snapshot option (+~20%) if you want a second safety net.
- [ ] Note the public IPv4 (and IPv6 if you will publish AAAA).
- [ ] Log in, create a non-root sudo user, then disable root/password SSH:
  ```bash
  adduser deploy && usermod -aG sudo deploy
  rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy
  # in /etc/ssh/sshd_config: PermitRootLogin no, PasswordAuthentication no
  systemctl restart ssh
  ```
- [ ] Updates: `apt update && apt -y upgrade && apt -y install unattended-upgrades ufw`.

## 2. Firewall: only SSH, 80, 443

Do this on the host **and** in the provider's cloud firewall if it has one.
Important: Docker publishes ports by editing iptables and **bypasses ufw**. This
compose file publishes only Caddy's 80/443, so that is fine, but never add a
`ports:` entry to postgres or backend.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp      # HTTP/3 (optional)
sudo ufw enable
sudo ufw status verbose
```

Port 80 must stay open: Caddy uses it for the ACME HTTP challenge and redirects.

## 3. DNS

- [ ] Create an **A record** `app.example.com → <server IPv4>` (and AAAA only if the server really has working IPv6).
- [ ] Wait until it resolves from your laptop: `dig +short app.example.com` returns the server IP. **Do not start Caddy before this**; Let's Encrypt rate-limits failed attempts.

## 4. Install Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker deploy      # log out and back in
docker --version && docker compose version
```

## 5. Copy the code to the server

`docker-compose.prod.yml` builds `../../frilance-backend` and `../../frilance-frontend`, so the
three directories must be siblings:

```
~/app/
  freelance-all/deploy/        docker-compose.prod.yml, .env.example, smoke-test.sh
  frilance-backend/
  frilance-frontend/
```

Either clone each repo at the tag you wrote down in step 0 (GitHub: `dianabirkovic-gif/frilance-backend`, `…/frilance-frontend`),
or rsync from your laptop:

```bash
mkdir -p ~/app && cd ~/app
git clone https://github.com/dianabirkovic-gif/frilance-backend.git
git clone https://github.com/dianabirkovic-gif/frilance-frontend.git
git -C frilance-backend checkout <tag-or-sha>
git -C frilance-frontend checkout <tag-or-sha>
# freelance-all/deploy is not in those repos; copy it from your laptop:
#   rsync -av "freelance-all/deploy/" deploy@SERVER:~/app/freelance-all/deploy/
```

## 6. Fill `deploy/.env`

```bash
cd ~/app/freelance-all/deploy
cp .env.example .env && chmod 600 .env
echo "DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')"   # paste into .env
echo "JWT_SECRET=$(openssl rand -base64 48)"                    # paste into .env
nano .env
```

Required values:

| Variable | Value |
|---|---|
| `SITE_ADDRESS` | `app.example.com` (bare hostname, no scheme → Caddy gets a certificate) |
| `CORS_ALLOWED_ORIGINS` | `https://app.example.com` — **https**, exact host, no trailing slash, must match `SITE_ADDRESS` |
| `DB_PASSWORD` | generated, not `frilanceos` (the backend refuses the default) |
| `JWT_SECRET` | `openssl rand -base64 48` output (≥ 32 bytes once decoded) |
| `VITE_API_BASE_URL` | leave `/api/v1` |

- [ ] `.env` is `chmod 600`, never committed, and the two secrets are also saved in a password manager (losing `JWT_SECRET` only logs everyone out; losing `DB_PASSWORD` after the volume exists means resetting it inside Postgres).
- [ ] `grep -c '=$' .env` shows no empty required value.

## 7. First start

```bash
cd ~/app/freelance-all/deploy
docker compose -f docker-compose.prod.yml --env-file .env config >/dev/null && echo "compose OK"
docker compose -f docker-compose.prod.yml --env-file .env up -d --build
```

The first build takes several minutes (Maven + npm). Then:

```bash
docker compose -f docker-compose.prod.yml ps            # postgres + backend: healthy (backend needs up to ~90 s)
docker compose -f docker-compose.prod.yml logs -f web   # watch for "certificate obtained successfully"
curl -fsS https://app.example.com/actuator/health       # {"status":"UP"}
```

If the backend exits immediately, read its log (`logs backend`): it fails fast and says which
variable is unset, a placeholder, or a wildcard origin.

## 8. Smoke test

`smoke-test.sh` (same directory) takes any base URL, needs only `curl`, and registers one
throwaway user `smoke-<timestamp>@example.com` in the target database. *(verified locally: all 13 checks pass against `http://localhost`.)*

```bash
./smoke-test.sh https://app.example.com
```

It checks: health 200; SPA root and deep route 200; missing `/assets/*` → 404; `/docs` and
`/v3/api-docs` → 404; `/actuator/env` not exposed; demo login (`diana@example.com`) → 401;
foreign-origin CORS preflight → 403; register returns a token; login 200; `/api/v1/clients`
401 without token, 200 with it.

Manual extras:

```bash
curl -sI http://app.example.com | head -3          # 308 redirect to https
curl -sI https://app.example.com | grep -i -E 'HTTP/|strict-transport|server'
echo | openssl s_client -connect app.example.com:443 -servername app.example.com 2>/dev/null | openssl x509 -noout -issuer -dates
ss -tlnp | grep -E ':(5432|8080)\b' || echo "5432/8080 not listening on the host (good)"
```

Then, from outside the server (phone on mobile data), confirm ports 5432 and 8080 are closed:
`nc -zv <server-ip> 5432` and `nc -zv <server-ip> 8080` should fail.

## 9. Backups (do before inviting anyone)

Nightly `pg_dump` in custom format, kept 14 days, copied off the box.

```bash
sudo mkdir -p /var/backups/frilance && sudo chown deploy: /var/backups/frilance
cat > ~/backup.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd ~/app/freelance-all/deploy
OUT=/var/backups/frilance/frilanceos-$(date +%F-%H%M).dump
docker compose -f docker-compose.prod.yml --env-file .env exec -T postgres \
  sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$OUT"
test -s "$OUT"                                   # fail loudly on an empty dump
find /var/backups/frilance -name '*.dump' -mtime +14 -delete
# off-box copy, e.g.: rclone copy "$OUT" b2:frilance-backups/   (or scp to another machine)
EOF
chmod +x ~/backup.sh && ~/backup.sh && ls -l /var/backups/frilance
(crontab -l 2>/dev/null; echo '15 3 * * * /home/deploy/backup.sh >> /home/deploy/backup.log 2>&1') | crontab -
```

**Restore test (do it once now, and after any schema change).** *(Dump + restore into a scratch DB verified locally.)*

```bash
cd ~/app/freelance-all/deploy
DC="docker compose -f docker-compose.prod.yml --env-file .env"
$DC exec -T postgres sh -c 'createdb -U "$POSTGRES_USER" restore_test'
$DC exec -T postgres sh -c 'pg_restore -U "$POSTGRES_USER" -d restore_test --no-owner' < /var/backups/frilance/<file>.dump
$DC exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d restore_test -Atc "select count(*) from user_account"'
$DC exec -T postgres sh -c 'dropdb -U "$POSTGRES_USER" restore_test'
```

Real disaster restore (replaces live data): `$DC stop backend web`, drop and recreate the database
(`dropdb`/`createdb`), `pg_restore -d "$POSTGRES_DB"` the dump, `$DC start backend web`.

**Never run `docker compose down -v` on this host** — it deletes the `pgdata` volume.
Plain `down`/`stop`/`restart` are safe.

## 10. Updating / redeploying

```bash
~/backup.sh                                              # always first
cd ~/app/frilance-backend  && git fetch --tags && git checkout <new-tag>
cd ~/app/frilance-frontend && git fetch --tags && git checkout <new-tag>
cd ~/app/freelance-all/deploy
docker compose -f docker-compose.prod.yml --env-file .env up -d --build
docker compose -f docker-compose.prod.yml ps
./smoke-test.sh https://app.example.com
```

- Flyway migrations are one-way. Never edit an applied migration. If the release adds a migration, the pre-deploy dump is your only way back.
- Frontend env (`VITE_API_BASE_URL`) is baked at build time; changing it needs `--build`.
- Rebuilding `web` or `backend` alone: `up -d --build backend` (users see a brief 502 during the restart).

## 11. Rollback

1. Code only (no new migration): check out the previous tag in both repos, `up -d --build`, run the smoke test.
2. Release included a migration: the old code may not run on the new schema. Stop `backend` and `web`, restore the pre-deploy dump (section 9, disaster restore), check out the previous tags, `up -d --build`, smoke test. Data written after the deploy is lost; say so to testers.
3. Keep the last two working image builds if you want faster rollback: `docker image ls`, tag them before rebuilding (`docker tag <image> <image>:prev`).

## 12. Logs and day-to-day

```bash
cd ~/app/freelance-all/deploy
DC="docker compose -f docker-compose.prod.yml --env-file .env"
$DC ps
$DC logs -f --tail=200 backend       # also: web (Caddy access/TLS), postgres
$DC logs --since 1h backend | grep -i -E 'error|exception'
$DC restart backend
docker stats --no-stream
df -h / ; docker system df
```

Logs rotate at 3 × 10 MB per container. Add an external uptime check on
`https://app.example.com/actuator/health` (UptimeRobot or similar) and alert to your phone.
Watch disk space: dumps and Docker images accumulate (`docker image prune -f` after deploys).

---

# Pre-invite checklist (before sending the link to testers)

**Code state**
- [ ] Both repos committed, pushed, tagged; the deployed SHAs are recorded.
- [ ] CI-equivalent run on that commit: `mvn clean test`, frontend lint/test/build all green.

**Infrastructure**
- [ ] Section 8 smoke test passes against the real domain; padlock shows a valid certificate.
- [ ] Backup cron has produced at least one non-empty dump and the restore test passed.
- [ ] Ports 5432/8080 unreachable from outside; SSH key-only.
- [ ] Uptime monitor is on.

**Manual click-through in a real browser (nobody has driven the prod stack in a browser yet)**
- [ ] Register a new account (both work modes if relevant) → lands logged in.
- [ ] Create a **client** → open it → edit it.
- [ ] Create a **content post** for that client (content plan) → change status.
- [ ] **Finance**: add an income and an expense entry → totals update.
- [ ] Reload on a deep route (e.g. `/clients/<id>`) → page loads (SPA fallback), not 404.
- [ ] Log out / log in again; invite a team member (the invite token is shown in the UI, not emailed) and claim it in a private window.
- [ ] Check on a phone (Ukrainian UI strings, layout).
- [ ] Delete your test data, or keep the account as a throwaway; do not leave `smoke-*@example.com` users if you care about counts.

**Decision: open registration and rate limiting**
`POST /api/v1/auth/register`, `/login` and `/claim-invite` are public and **unthrottled**; Caddy
has no rate-limit module in the stock image. Pick one before inviting:
- [ ] Accept for a small closed test (unlisted hostname, small tester list), monitor `logs web` for floods; **or**
- [ ] Put Cloudflare (proxy + rate-limiting rule on `/api/v1/auth/*`) in front; **or**
- [ ] Add a code-level limiter / invite-only registration flag first (follow-up work).
Write down which one you chose.

**Privacy and data notes for (Ukrainian) testers**
- [ ] Tell testers: where data lives (EU VPS, provider + country), that it is a **test** service, that backups exist (14 days), and how to ask for deletion (a contact email you actually read).
- [ ] The app stores third-party personal data (clients' names, phones, emails, finance entries). Testers are effectively controllers of their clients' data; advise them to use fake or minimal data during the test.
- [ ] No email is sent by the app (no SMTP): password reset does not exist; say so. Passwords are bcrypt-hashed; tokens live in browser `localStorage` for 24 h with no revocation.
- [ ] The service uses no analytics or third-party scripts as far as known; confirm the built frontend loads no external fonts/scripts (`curl -s https://app.example.com | grep -i -E 'src=|href='`) before saying so.
- [ ] A short Ukrainian-language notice (what is collected, where, how long, contact) at the invite message or on the register screen is the minimum; GDPR applies if any tester is in the EU.
- [ ] Decide what happens to the data when the test ends (delete the volume or migrate), and tell testers.

---

# Known unverified items

- **Real HTTPS / ACME has never been exercised.** Only plain HTTP (`SITE_ADDRESS=:80`) was run locally. Certificate issuance, HTTP→HTTPS redirect, HSTS and the `https://` CORS match are untested until the first real deploy; the smoke test and section 8 manual checks cover them then.
- **DB upgrade path is untested.** A database that previously applied the demo seed migrations (V2/V4/V16) will report them as applied-but-missing under the prod profile. Always start prod from a fresh database; never point it at an old dev DB. Future-migration behaviour on a populated prod DB has not been rehearsed — hence the dump-before-deploy rule.
- **Default DB password rejection inside a container** was not demonstrated end-to-end (covered by `ProdConfigurationGuardTest` only).
- **Browser UI against the prod stack** has not been driven (only HTTP-level checks).
- **Server hardening, cron backup and off-box copy** steps above are written, not run on a real VPS. Only the `pg_dump`/`pg_restore` commands were run (locally).
- **Performance and memory** on a 4 GB box under real load are unknown (JVM capped at 70% of container RAM by the Dockerfile).
