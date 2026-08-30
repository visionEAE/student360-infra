-- The audit trail is owned by the infrastructure, not by any service: no service migration may
-- touch it, and the engine — not application code — guarantees it is append-only.
-- (docs/context.md §6)

CREATE TABLE audit.audit_record (
    id                   BIGSERIAL PRIMARY KEY,
    occurred_at          TIMESTAMPTZ  NOT NULL,
    request_id           TEXT         NOT NULL,
    trace_id             TEXT,
    service_name         TEXT         NOT NULL,  -- which service wrote it
    record_type          TEXT         NOT NULL,  -- DATA_ACCESS | SECURITY | STATE_CHANGE
    action               TEXT         NOT NULL,  -- READ_FINANCIAL_STATUS, LOGIN_FAILED, ...
    actor_id             UUID,                   -- who performed the action
    actor_roles          TEXT[],
    subject_type         TEXT,                   -- STUDENT | SESSION | ALERT
    subject_id           TEXT,                   -- who or what it acted upon
    authorization_basis  TEXT,                   -- SELF | ASSIGNMENT | ADMIN_ROLE | NONE
    outcome              TEXT         NOT NULL,  -- ALLOWED | DENIED
    source_ip            TEXT,
    details              JSONB,                  -- extra context; never sensitive values in clear text
    CONSTRAINT chk_audit_record_type    CHECK (record_type IN ('DATA_ACCESS', 'SECURITY', 'STATE_CHANGE')),
    CONSTRAINT chk_audit_record_outcome CHECK (outcome IN ('ALLOWED', 'DENIED'))
);

CREATE INDEX idx_audit_record_request_id ON audit.audit_record (request_id);
CREATE INDEX idx_audit_record_subject    ON audit.audit_record (subject_type, subject_id, occurred_at DESC);

GRANT USAGE ON SCHEMA audit TO auth_user, core_user, lms_user, support_user;
GRANT INSERT, SELECT ON audit.audit_record TO auth_user, core_user, lms_user, support_user;
GRANT USAGE ON SEQUENCE audit.audit_record_id_seq TO auth_user, core_user, lms_user, support_user;
-- Deliberately absent: UPDATE, DELETE, TRUNCATE.
