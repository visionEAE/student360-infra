#!/usr/bin/env bash
# Phase gate 2 against running auth-service (8081) and gateway (8080):
#   no token → 401 · STUDENT on an advisor route → 403 · a source that is down → 503 fallback with
#   its section · SSO routes forwarded untouched · gateway and SSO log lines share requestId/traceId.
# Optional: LOG_DIR pointing at the folder holding gateway.log and auth-service.log.
set -uo pipefail
G="${GATEWAY_URL:-http://localhost:8080}"
EMAIL="${DEMO_EMAIL:-ana.torres@u.icesi.edu.co}"; PASSWORD="${DEMO_PASSWORD:-student360}"
rid="gate2-$(date +%s)"
failed=0; pass() { echo "✔ $1"; }; fail() { echo "✖ $1"; failed=1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

login="$(curl -s -H 'Content-Type: application/json' -H "X-Request-Id: $rid" -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" "$G/api/auth/login")"
tok="$(jq -r '.accessToken // empty' <<<"$login")"
[ -n "$tok" ] && pass "login through the gateway (request id $rid)" || { fail "login: $login"; exit 1; }

c="$(code "$G/api/core/students/S-1001")"; [ "$c" = 401 ] && pass "no token → 401" || fail "no token → $c"
c="$(code -H "Authorization: Bearer $tok" "$G/api/support/advisors/me/alerts")"; [ "$c" = 403 ] && pass "STUDENT on /api/support/advisors → 403 (coarse layer)" || fail "expected 403, got $c"
body="$(curl -s -H "Authorization: Bearer $tok" "$G/api/core/students/S-1001")"
if jq -e '.status == 503 and .section == "student-records"' <<<"$body" >/dev/null; then pass "core-service unreachable → 503 fallback, section=student-records"
elif jq -e '.id' <<<"$body" >/dev/null 2>&1; then pass "core-service reachable → student record returned"
else fail "unexpected core response: $body"; fi
me="$(curl -s -H "Authorization: Bearer $tok" "$G/api/auth/me")"; jq -e '.externalReference' <<<"$me" >/dev/null && pass "/api/auth/me forwarded untouched ($(jq -r .email <<<"$me"))" || fail "/me: $me"

if [ -n "${LOG_DIR:-}" ] && [ -f "$LOG_DIR/gateway.log" ] && [ -f "$LOG_DIR/auth-service.log" ]; then
  sleep 1
  traces="$(grep -h "\"requestId\":\"$rid\"" "$LOG_DIR/gateway.log" "$LOG_DIR/auth-service.log" | jq -r '"\(.service)\t\(.requestId)\t\(.traceId)\t\(.message[0:60])"')"
  echo "$traces" | column -t -s $'\t'
  n="$(echo "$traces" | cut -f3 | sort -u | grep -c .)"
  [ "$n" = 1 ] && pass "gateway and auth-service share one traceId for request $rid" || fail "traceIds differ ($n distinct)"
fi
[ "$failed" -eq 0 ] && echo "Phase gate 2: PASSED" || { echo "Phase gate 2: FAILED"; exit 1; }
