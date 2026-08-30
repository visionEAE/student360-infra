#!/usr/bin/env bash
# Phase gate 0.A: the database itself enforces schema isolation and the append-only audit table.
# Every check below must FAIL with "permission denied" for the gate to pass.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
port="${POSTGRES_PORT:-5432}"

expect_denied() { # <user> <password> <sql> <label>
  local out
  out="$(PGPASSWORD="$2" psql -h localhost -p "$port" -U "$1" -d "${POSTGRES_DB:-student360}" -v ON_ERROR_STOP=1 -tAc "$3" 2>&1)"
  if grep -q "permission denied" <<<"$out"; then echo "✔ denied  $4"; else echo "✖ ALLOWED $4 → $out"; failed=1; fi
}
expect_allowed() {
  local out
  out="$(PGPASSWORD="$2" psql -h localhost -p "$port" -U "$1" -d "${POSTGRES_DB:-student360}" -v ON_ERROR_STOP=1 -tAc "$3" 2>&1)" \
    && echo "✔ allowed $4" || { echo "✖ DENIED  $4 → $out"; failed=1; }
}

failed=0
expect_denied  lms_user  "$LMS_DB_PASSWORD"  "SELECT count(*) FROM auth.app_user"            "lms_user reading auth schema"
expect_denied  lms_user  "$LMS_DB_PASSWORD"  "CREATE TABLE core.intruder (id int)"           "lms_user creating a table in core schema"
expect_allowed lms_user  "$LMS_DB_PASSWORD"  "CREATE TABLE lms.gate_probe (id int); DROP TABLE lms.gate_probe" "lms_user owning its schema"
expect_allowed auth_user "$AUTH_DB_PASSWORD" "INSERT INTO audit.audit_record (occurred_at, request_id, service_name, record_type, action, outcome) VALUES (now(), 'gate-probe', 'check-isolation', 'SECURITY', 'GATE_PROBE', 'ALLOWED')" "auth_user inserting an audit record"
expect_allowed core_user "$CORE_DB_PASSWORD" "SELECT count(*) FROM audit.audit_record"       "core_user reading the audit trail"
expect_denied  auth_user "$AUTH_DB_PASSWORD" "UPDATE audit.audit_record SET outcome = 'DENIED' WHERE request_id = 'gate-probe'" "auth_user updating an audit record"
expect_denied  auth_user "$AUTH_DB_PASSWORD" "DELETE FROM audit.audit_record WHERE request_id = 'gate-probe'" "auth_user deleting an audit record"
expect_denied  support_user "$SUPPORT_DB_PASSWORD" "TRUNCATE audit.audit_record"             "support_user truncating the audit trail"

[ "$failed" -eq 0 ] && echo "Phase gate 0.A: PASSED" || { echo "Phase gate 0.A: FAILED"; exit 1; }
