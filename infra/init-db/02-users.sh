#!/usr/bin/env bash
# Creates one database role per service. Written as a shell step (not plain SQL) only because the
# passwords come from the environment; the grants themselves are the point:
#   - USAGE + CREATE on the service's own schema, nothing on any other schema;
#   - INSERT + SELECT on audit.audit_record (granted in 03-audit.sql), never UPDATE or DELETE.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v auth_pw="$AUTH_DB_PASSWORD" -v core_pw="$CORE_DB_PASSWORD" \
  -v lms_pw="$LMS_DB_PASSWORD" -v support_pw="$SUPPORT_DB_PASSWORD" \
  -v network_pw="$NETWORK_DB_PASSWORD" <<'SQL'
CREATE ROLE auth_user    LOGIN PASSWORD :'auth_pw';
CREATE ROLE core_user    LOGIN PASSWORD :'core_pw';
CREATE ROLE lms_user     LOGIN PASSWORD :'lms_pw';
CREATE ROLE support_user LOGIN PASSWORD :'support_pw';
CREATE ROLE network_user LOGIN PASSWORD :'network_pw';

-- Each service owns its schema so Flyway can create and alter tables inside it. network_user's
-- schema holds only its outbox and reads the shared audit table — the graph itself lives in
-- Neo4j, not here.
ALTER SCHEMA auth    OWNER TO auth_user;
ALTER SCHEMA core    OWNER TO core_user;
ALTER SCHEMA lms     OWNER TO lms_user;
ALTER SCHEMA support OWNER TO support_user;
ALTER SCHEMA network OWNER TO network_user;

-- Flyway's own history table lives in the service schema, so no extra grant is needed.
ALTER ROLE auth_user    SET search_path = auth;
ALTER ROLE core_user    SET search_path = core;
ALTER ROLE lms_user     SET search_path = lms;
ALTER ROLE support_user SET search_path = support;
ALTER ROLE network_user SET search_path = network;
SQL
