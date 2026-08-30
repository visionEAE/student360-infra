-- One PostgreSQL instance, one schema per service (declared assumption 1 in docs/context.md).
-- Runs once at first container start, as the superuser, against ${POSTGRES_DB}.

CREATE SCHEMA auth;
CREATE SCHEMA core;
CREATE SCHEMA lms;
CREATE SCHEMA support;
CREATE SCHEMA network;
CREATE SCHEMA audit;

-- Nobody but the owner gets anything on public by default; each service is confined below.
REVOKE ALL ON SCHEMA public FROM PUBLIC;
