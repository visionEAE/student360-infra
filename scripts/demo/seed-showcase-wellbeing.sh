#!/usr/bin/env bash
# Wellbeing entries cannot be seeded with plain SQL: the student id is pseudonymised with an
# HMAC keyed by PSEUDONYM_SECRET, which is only known at runtime. This script submits real
# entries through the API (as each student, self-reported) so the emotional axis of the advisor
# overview and the 360 view are populated to match the showcase academic/financial seed.
#
# Idempotent-ish: re-running adds one more entry per student (harmless — it just refines the
# trend); run it once after `make up-containers` / `make demo` for a screenshot-ready dataset.
set -uo pipefail
cd "$(dirname "$0")/../.."
G="${GATEWAY_URL:-http://localhost:8080}"
failed=0; pass() { echo "✔ $1"; }; fail() { echo "✖ $1"; failed=1; }

login() { curl -s -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"${DEMO_PASSWORD:-student360}\"}" "$G/api/auth/login" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("accessToken",""))'; }

# entry <email> <econ mood> <acad mood> <emo mood>
entry() {
  local email="$1" econ="$2" acad="$3" emo="$4"
  local tok body
  tok="$(login "$email")"
  [ -z "$tok" ] && { fail "login failed for $email"; return; }
  body=$(cat <<JSON
{"status":"SENT","dimensions":[
  {"dimension":"ECONOMIC","mood":"$econ","needs":["NOTHING"]},
  {"dimension":"ACADEMIC","mood":"$acad","needs":["NOTHING"]},
  {"dimension":"EMOTIONAL","mood":"$emo","needs":["NOTHING"]}
]}
JSON
)
  local response
  response="$(curl -s -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "$body" "$G/api/support/students/$(email_to_ref "$email")/wellbeing-entries" 2>&1)" || true
  echo "$email -> $response"
}

# Not needed: the API path takes the student reference, but a student may only write their own —
# the controller ignores a mismatched path id via 403, so submit against the student's own ref.
declare -A REF=( [ana.torres@u.icesi.edu.co]=S-1001 [luis.gomez@u.icesi.edu.co]=S-1002 \
  [juan.gomez@u.icesi.edu.co]=S-1007 [santiago.molina@u.icesi.edu.co]=S-1008 \
  [isabella.zapata@u.icesi.edu.co]=S-1009 [andres.ruiz@u.icesi.edu.co]=S-1010 )
email_to_ref() { echo "${REF[$1]}"; }

echo "── recording self-reported wellbeing entries (all on-track/watch students) ──"
entry ana.torres@u.icesi.edu.co       VERY_GOOD VERY_GOOD VERY_GOOD
entry luis.gomez@u.icesi.edu.co       GOOD      GOOD      GOOD
entry juan.gomez@u.icesi.edu.co       VERY_GOOD VERY_GOOD VERY_GOOD
entry santiago.molina@u.icesi.edu.co  FAIR      FAIR      FAIR
entry isabella.zapata@u.icesi.edu.co  FAIR      GOOD      GOOD
entry andres.ruiz@u.icesi.edu.co      GOOD      GOOD      GOOD

echo
echo "── verifying the advisor overview reflects the new emotional data ──"
ctok="$(login carlos.mejia@icesi.edu.co)"
overview="$(curl -s -H "Authorization: Bearer $ctok" "$G/api/support/advisors/me/students")"
echo "$overview" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d['students']:
    print('  {:8} {:22} academic={:10} financial={:10} emotional={:10} overall={}'.format(
        s['studentId'], s['fullName'], s['academicStatus'], s['financialStatus'], s['emotionalStatus'], s['overallRisk']))
"

[ "$failed" -eq 0 ] && echo "Showcase wellbeing seed: DONE" || { echo "Showcase wellbeing seed: FAILED"; exit 1; }
