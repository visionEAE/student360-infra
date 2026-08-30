#!/usr/bin/env bash
# Phase gate 1 against a running auth-service (default http://localhost:8081).
# Needs: curl, jq, psql (for the audit query) and the .env of student360-infra.
#   1. login returns an access + refresh token pair
#   2. the access token verifies against the published JWKS (header kid matches, claims present)
#   3. refresh rotates: the old refresh token stops working
#   4. replaying the consumed token revokes the whole family and leaves a SECURITY audit record
#   5. logout kills the session
set -uo pipefail
cd "$(dirname "$0")/../.."
set -a; source .env; set +a
BASE="${AUTH_URL:-http://localhost:8081}"
EMAIL="${DEMO_EMAIL:-ana.torres@u.icesi.edu.co}"
PASSWORD="${DEMO_PASSWORD:-student360}"
failed=0
pass() { echo "✔ $1"; }
fail() { echo "✖ $1"; failed=1; }
status_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "── 1. login"
login="$(curl -s -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" "$BASE/api/auth/login")"
access="$(jq -r '.accessToken // empty' <<<"$login")"; refresh1="$(jq -r '.refreshToken // empty' <<<"$login")"; session="$(jq -r '.sessionId // empty' <<<"$login")"
[ -n "$access" ] && [ -n "$refresh1" ] && pass "token pair issued (session $session)" || { fail "login: $login"; exit 1; }

echo "── 2. decoded access token"
payload="$(cut -d. -f2 <<<"$access" | tr '_-' '/+' | awk '{ l=length($0)%4; if (l==2) print $0"=="; else if (l==3) print $0"="; else print $0 }' | base64 -d 2>/dev/null)"
jq . <<<"$payload"
kid="$(cut -d. -f1 <<<"$access" | tr '_-' '/+' | awk '{ l=length($0)%4; if (l==2) print $0"=="; else if (l==3) print $0"="; else print $0 }' | base64 -d 2>/dev/null | jq -r .kid)"
jwks_kid="$(curl -s "$BASE/.well-known/jwks.json" | jq -r '.keys[0].kid')"
[ "$kid" = "$jwks_kid" ] && pass "token kid '$kid' is published in JWKS" || fail "kid mismatch: token=$kid jwks=$jwks_kid"
[ "$(jq -r '.aud' <<<"$payload")" = "student360-api" ] && pass "aud = student360-api" || fail "unexpected aud"
[ -n "$(jq -r '.ref // empty' <<<"$payload")" ] && pass "ref claim = $(jq -r .ref <<<"$payload"), roles = $(jq -c .roles <<<"$payload")" || fail "ref claim missing"

echo "── 3. refresh rotates"
rotated="$(curl -s -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$refresh1\"}" "$BASE/api/auth/refresh")"
refresh2="$(jq -r '.refreshToken // empty' <<<"$rotated")"
[ -n "$refresh2" ] && [ "$refresh2" != "$refresh1" ] && pass "new refresh token issued, same session $(jq -r .sessionId <<<"$rotated")" || fail "rotation failed: $rotated"

echo "── 4. replay of the consumed token"
code="$(status_of -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$refresh1\"}" "$BASE/api/auth/refresh")"
[ "$code" = "401" ] && pass "consumed token replay → 401" || fail "expected 401, got $code"
code="$(status_of -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$refresh2\"}" "$BASE/api/auth/refresh")"
[ "$code" = "401" ] && pass "fresh token of the same family → 401 (family revoked)" || fail "expected 401 for the sibling token, got $code"
reason="$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h localhost -p "${POSTGRES_PORT:-5432}" -U postgres -d "${POSTGRES_DB:-student360}" -tAc "SELECT revocation_reason FROM auth.auth_session WHERE id = '$session'")"
[ "$reason" = "REUSE_DETECTED" ] && pass "auth_session.revocation_reason = REUSE_DETECTED" || fail "session reason: '$reason'"
echo "   audit trail of session $session:"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h localhost -p "${POSTGRES_PORT:-5432}" -U postgres -d "${POSTGRES_DB:-student360}" -c "SELECT occurred_at, action, outcome, authorization_basis, request_id, details FROM audit.audit_record WHERE subject_id = '$session' OR (action = 'REFRESH_REJECTED' AND occurred_at > now() - interval '1 minute') ORDER BY id"

echo "── 5. logout"
login="$(curl -s -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" "$BASE/api/auth/login")"
refresh3="$(jq -r .refreshToken <<<"$login")"
code="$(status_of -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$refresh3\"}" "$BASE/api/auth/logout")"
[ "$code" = "204" ] && pass "logout → 204" || fail "logout returned $code"
code="$(status_of -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$refresh3\"}" "$BASE/api/auth/refresh")"
[ "$code" = "401" ] && pass "refresh after logout → 401" || fail "expected 401 after logout, got $code"

[ "$failed" -eq 0 ] && echo "Phase gate 1: PASSED" || { echo "Phase gate 1: FAILED"; exit 1; }
