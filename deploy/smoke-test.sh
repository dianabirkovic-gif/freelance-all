#!/usr/bin/env bash
# Smoke test for a running Frilance OS stack. Usage: ./smoke-test.sh https://app.example.com
# Registers one throwaway user (smoke-<timestamp>@example.com) in the target DB.
# Needs: curl. Exit code 0 = all checks passed.
set -u
BASE="${1:?usage: $0 <base-url, e.g. https://app.example.com or http://localhost>}"
BASE="${BASE%/}"
fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1 (expected $2, got $3)"; fail=1; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@"; }

check "health"                       200 "$(code "$BASE/actuator/health")"
check "SPA root"                     200 "$(code "$BASE/")"
check "SPA deep route fallback"      200 "$(code "$BASE/clients/deep/route")"
check "missing asset is 404"         404 "$(code "$BASE/assets/nonexistent.js")"
check "/docs blocked"                404 "$(code "$BASE/docs")"
check "/v3/api-docs blocked"         404 "$(code "$BASE/v3/api-docs")"
# Caddy proxies only /actuator/health; other actuator paths must not reach the backend.
ENV_BODY=$(curl -s --max-time 20 "$BASE/actuator/env")
case "$ENV_BODY" in *activeProfiles*|*propertySources*) echo "FAIL  /actuator/env exposed"; fail=1 ;; *) echo "PASS  /actuator/env not exposed" ;; esac
check "demo login rejected"          401 "$(code -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"diana@example.com","password":"password123"}')"
check "foreign-origin CORS refused"  403 "$(code -X OPTIONS "$BASE/api/v1/clients" -H 'Origin: https://evil.example' \
  -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: authorization')"

TS=$(date +%s)
EMAIL="smoke-$TS@example.com"
PASS="smoke-$TS-pw"
REG=$(curl -s --max-time 20 -X POST "$BASE/api/v1/auth/register" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"fullName\":\"Smoke Test\",\"workMode\":\"FREELANCER\"}")
TOKEN=$(printf '%s' "$REG" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
if [ -n "$TOKEN" ]; then echo "PASS  register returns token"; else echo "FAIL  register (response: $REG)"; fail=1; fi
LOGIN_BODY="{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}"
check "login"                        200 "$(code -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' -d "$LOGIN_BODY")"
check "clients without token"        401 "$(code "$BASE/api/v1/clients")"
check "clients with token"           200 "$(code "$BASE/api/v1/clients" -H "Authorization: Bearer $TOKEN")"

[ "$fail" = 0 ] && echo "ALL OK" || echo "SOME CHECKS FAILED"
exit "$fail"
