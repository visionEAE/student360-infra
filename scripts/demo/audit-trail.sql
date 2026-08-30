-- Reconstruct the path of one request across the services it touched.
--   psql ... -v request_id='demo-...-entry' -f scripts/demo/audit-trail.sql
SELECT occurred_at, service_name, record_type, action, outcome, authorization_basis, actor_id, subject_type, subject_id, trace_id
FROM audit.audit_record
WHERE request_id = :'request_id'
ORDER BY occurred_at;
