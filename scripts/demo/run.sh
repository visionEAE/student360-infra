#!/usr/bin/env bash
# The demonstration thread (docs/context.md §8) end to end, through the gateway, with both
# negative scenarios. Needs all five services running (make run-<service> ×5) and .env.
#   1  student logs in                               6  the rule fires an explainable alert
#   2  360° view: core + lms                         7  assigned advisor sees and opens it (ASSIGNMENT)
#   3  (gateway strips the token, adds identity)     8  audit trail of ONE request across services
#   4  lms signals                                   9  negative A: unassigned advisor → 403 + DENIED
#   5  low wellbeing entry → pseudonymised + outbox 10  negative B: refresh replay → family revoked
set -uo pipefail
cd "$(dirname "$0")/../.."
set -a; source .env; set +a
G="${GATEWAY_URL:-http://localhost:8080}"
PSQL=(psql -h localhost -p "${POSTGRES_PORT:-5432}" -U postgres -d "${POSTGRES_DB:-student360}")
export PGPASSWORD="$POSTGRES_PASSWORD"
failed=0; pass() { echo "  ✔ $1"; }; fail() { echo "  ✖ $1"; failed=1; }
login() { curl -s -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"${DEMO_PASSWORD:-student360}\"}" "$G/api/auth/login"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
stamp="$(date +%H%M%S)"

echo "── 1. student logs in (María Rojas, S-1003 — the at-risk student)"
s="$(login maria.rojas@u.icesi.edu.co)"; stok="$(jq -r .accessToken <<<"$s")"; srefresh="$(jq -r .refreshToken <<<"$s")"
[ -n "$stok" ] && [ "$stok" != null ] && pass "access + refresh token issued (session $(jq -r .sessionId <<<"$s"))" || { fail "login: $s"; exit 1; }
echo "     claims: $(cut -d. -f2 <<<"$stok" | tr '_-' '/+' | awk '{l=length($0)%4; if(l==2)print $0"=="; else if(l==3)print $0"="; else print $0}' | base64 -d 2>/dev/null | jq -c '{sub,roles,ref,aud,jti}')"

echo "── 2–4. 360° view through the gateway (identity rewritten, service token attached)"
for path in "/api/core/students/S-1003" "/api/core/students/S-1003/academic-status" "/api/core/students/S-1003/financial-status" "/api/lms/students/S-1003/signals"; do
  body="$(curl -s -H "Authorization: Bearer $stok" "$G$path")"
  if jq -e '(.status|type) == "number" and .status >= 400' <<<"$body" >/dev/null 2>&1; then fail "$path → $(jq -c '{status,title,section}' <<<"$body")"; else pass "$path → $(jq -c 'if has("academicStanding") then {academicStanding,cumulativeGpa} elif has("overdue") then {overdue,daysOverdue,financialHold} elif has("daysSinceLastAccess") then {daysSinceLastAccess,onTimeSubmissionRate,coursesWithoutActivity} else {fullName,status} end' <<<"$body")"; fi
done
c="$(code -H "Authorization: Bearer $stok" "$G/api/core/students/S-1001/financial-status")"; [ "$c" = 403 ] && pass "another student's financial status → 403 (fine-grained layer, audited DENIED)" || fail "expected 403, got $c"
c="$(code -H "Authorization: Bearer $stok" "$G/api/support/advisors/me/alerts")"; [ "$c" = 403 ] && pass "advisor inbox with a STUDENT token → 403 (coarse layer)" || fail "expected 403, got $c"

echo "── 5–6. low wellbeing entry → rule evaluates core + lms signals synchronously"
rid="demo-$stamp-entry"
entry_body='{"status":"SENT","dimensions":[
  {"dimension":"ECONOMIC","mood":"DIFFICULT","needs":["PAYMENT_PLAN"],"note":"I am behind on payments"},
  {"dimension":"ACADEMIC","mood":"DIFFICULT","needs":["TUTORING"]},
  {"dimension":"EMOTIONAL","mood":"DIFFICULT","needs":["TALK_TO_SOMEONE"],"note":"I feel overwhelmed"}
]}'
entry="$(curl -s -H "Authorization: Bearer $stok" -H "X-Request-Id: $rid" -H 'Content-Type: application/json' -d "$entry_body" "$G/api/support/students/S-1003/wellbeing-entries")"
alert="$(jq -r '.alertId // empty' <<<"$entry")"
[ -n "$alert" ] && pass "entry recorded, alert $alert generated (request id $rid)" || { fail "entry: $entry"; }
"${PSQL[@]}" -tAc "SELECT severity || ' · fired=' || (triggering_signals->'firedConditions')::text FROM support.alert WHERE id = '$alert'" 2>/dev/null | sed 's/^/     alert: /'
"${PSQL[@]}" -tAc "SELECT 'pseudonym ' || left(student_pseudonym, 16) || '… (never the student id)' FROM support.wellbeing_entry ORDER BY recorded_at DESC LIMIT 1" | sed 's/^/     entry:  /'

echo "── 7. assigned advisor (Carlos Mejía, A-2001) sees the alert and opens it"
a="$(login carlos.mejia@icesi.edu.co)"; atok="$(jq -r .accessToken <<<"$a")"
inbox="$(curl -s -H "Authorization: Bearer $atok" "$G/api/support/advisors/me/alerts")"
jq -e --arg id "$alert" 'map(select(.id == $id)) | length == 1' <<<"$inbox" >/dev/null && pass "alert is in A-2001's inbox ($(jq length <<<"$inbox") alerts)" || fail "inbox: $(cut -c1-120 <<<"$inbox")"
rid_detail="demo-$stamp-detail"
detail="$(curl -s -H "Authorization: Bearer $atok" -H "X-Request-Id: $rid_detail" "$G/api/support/advisors/me/alerts/$alert")"
jq -e '.interventionPlan.type' <<<"$detail" >/dev/null && pass "detail opened: plan $(jq -r .interventionPlan.type <<<"$detail"), signals $(jq -c .triggeringSignals.firedConditions <<<"$detail")" || fail "detail: $(cut -c1-120 <<<"$detail")"
basis="$("${PSQL[@]}" -tAc "SELECT authorization_basis FROM audit.audit_record WHERE request_id = '$rid_detail' AND action = 'READ_ALERT_DETAIL'")"
[ "$basis" = ASSIGNMENT ] && pass "audited with authorization_basis = ASSIGNMENT" || fail "basis for detail: '$basis'"

echo "── 8. one request, several services: audit trail of $rid"
"${PSQL[@]}" -c "SELECT to_char(occurred_at, 'HH24:MI:SS.MS') AS at, service_name, action, outcome, authorization_basis AS basis, actor_id FROM audit.audit_record WHERE request_id = '$rid' ORDER BY occurred_at" | sed 's/^/     /'
n="$("${PSQL[@]}" -tAc "SELECT count(DISTINCT service_name) FROM audit.audit_record WHERE request_id = '$rid'")"
[ "$n" -ge 3 ] && pass "$n services wrote audit records for the same request id" || fail "only $n services in the trail"

echo "── 9. negative A: Diana Pérez (A-2002, no active assignment to S-1003) opens the same alert"
d="$(login diana.perez@icesi.edu.co)"; dtok="$(jq -r .accessToken <<<"$d")"; rid_denied="demo-$stamp-denied"
c="$(code -H "Authorization: Bearer $dtok" -H "X-Request-Id: $rid_denied" "$G/api/support/advisors/me/alerts/$alert")"
[ "$c" = 403 ] && pass "→ 403" || fail "expected 403, got $c"
"${PSQL[@]}" -tAc "SELECT action || ' ' || outcome || ' basis=' || authorization_basis FROM audit.audit_record WHERE request_id = '$rid_denied'" | sed 's/^/     audit: /'
"${PSQL[@]}" -tAc "SELECT outcome FROM audit.audit_record WHERE request_id = '$rid_denied'" | grep -q DENIED && pass "audit record with outcome = DENIED" || fail "no DENIED record"

echo "── 10. negative B: a consumed refresh token is replayed"
rot="$(curl -s -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$srefresh\"}" "$G/api/auth/refresh")"; rot2="$(jq -r .refreshToken <<<"$rot")"
c="$(code -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$srefresh\"}" "$G/api/auth/refresh")"; [ "$c" = 401 ] && pass "replay of the consumed token → 401" || fail "replay → $c"
c="$(code -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$rot2\"}" "$G/api/auth/refresh")"; [ "$c" = 401 ] && pass "the fresh token of the same family is dead too → 401" || fail "sibling → $c"
"${PSQL[@]}" -tAc "SELECT 'session ' || id || ' revoked: ' || revocation_reason FROM auth.auth_session WHERE id = '$(jq -r .sessionId <<<"$s")'" | sed 's/^/     /'
"${PSQL[@]}" -tAc "SELECT action || ' ' || outcome || ' ' || details::text FROM audit.audit_record WHERE action = 'REFRESH_TOKEN_REUSED' AND subject_id = '$(jq -r .sessionId <<<"$s")'" | sed 's/^/     security: /'

echo "── outbox: what would be published"
"${PSQL[@]}" -c "SELECT event_type, aggregate_id, left(payload::text, 110) || '…' AS payload FROM support.outbox_event WHERE payload->>'requestId' = '$rid' ORDER BY created_at" | sed 's/^/     /'

[ "$failed" -eq 0 ] && echo "Demonstration thread: PASSED" || { echo "Demonstration thread: FAILED"; exit 1; }
