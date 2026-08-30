# Student 360° View — Context Document
## Version 3 · Scope: local development environment · Language: English throughout

**Deliverable type:** architectural proof of concept, runnable on a local machine.
**Out of scope in this version:** GCP deployment, Pub/Sub, BigQuery, VPN, IAP, Secret Manager.
**Language policy:** all code, identifiers, comments, commit messages, database objects, API contracts and documentation are written in English. Domain terms are translated once in section 3 and never mixed afterwards.

> The implementation plan derived from this document lives in [implementation-plan.md](implementation-plan.md).

---

## PART I — CONTEXT

### 1. What this proof of concept is, and what it is not

This is a **locally runnable architectural proof of concept**. The goal is not a feature-complete product or a cloud deployment, but a demonstration that **the systems communicate correctly with each other**: that identity travels end to end, that authorization is enforced at two distinct layers, that one service can orchestrate two others synchronously and securely, and that everything that happens is traceable and auditable.

The work is split into two stages, and this document covers **stage 1 only**.

| Stage 1 — local/dev (this version) | Stage 2 — cloud (later) |
|---|---|
| Five services running on `localhost` | Cloud Run deployment |
| PostgreSQL in Docker, separate schemas | Private Cloud SQL via Cloud SQL Auth Proxy |
| Domain events written to an `outbox` table | Real publication to Pub/Sub |
| Audit trail in an append-only table | Export to Cloud Storage with bucket lock |
| Structured JSON logging + correlation ids | Cloud Logging, Cloud Trace, Cloud Monitoring |
| Locally signed service-to-service token | Google-signed ID token with audience |
| No warehouse | BigQuery via native subscription |

**The governing principle of stage 1:** everything that will become a managed cloud service is implemented locally **behind an interface**, so that moving to stage 2 means swapping an adapter implementation, never rewriting domain logic. This must be demonstrable by pointing at the code.

Not implemented in this stage: password recovery, MFA, user management UI, predictive model, analytics dashboards, or the full use-case catalogue. When forced to choose between one more feature and one well-demonstrated interaction between components, choose the second.

---

### 2. Problem statement

Student 360° View consolidates a student's academic, financial, learning-platform activity and emotional wellbeing data into a single view, so that the student support team can detect risk situations and trigger early intervention plans. The long-term goal is to feed a predictive model; the goal of this stage is a working system that is ready to feed one.

---

### 3. Domain glossary (Spanish → English)

Fixed once, used consistently everywhere. No mixed-language identifiers.

| Spanish (original brief) | English (used in code) |
|---|---|
| Estudiante | Student |
| Acompañante | Advisor |
| Seguimiento / acompañamiento | Support |
| Registro de bienestar / estado anímico | Wellbeing entry |
| Alerta temprana | Alert |
| Ruta de intervención | Intervention plan |
| Asignación de acompañante | Advisor assignment |
| Auditoría | Audit |

---

### 4. The five systems

| Service | Local port | DB schema | Responsibility |
|---|---|---|---|
| `gateway` | 8080 | — | Single entry point. Validates JWT, enforces coarse role/route authorization, rewrites identity, routes. |
| `auth-service` | 8081 | `auth` | Custom SSO. Issues tokens, rotates refresh tokens, detects reuse, exposes JWKS. |
| `core-service` | 8082 | `core` | Simulates SIS + ERP. Source of truth for student identity, official academic status and financial status. |
| `lms-service` | 8083 | `lms` | Simulates the learning platform. Courses, submissions, access logs, engagement signals. |
| `support-service` | 8084 | `support` | All new functionality. Wellbeing entries, risk rules, alerts, intervention plans, advisor reports. |
| `frontend` | 5173 | — | Minimal SPA. |

#### Why the LMS is a separate service and not part of `core-service`

This reverses an earlier consolidation, so the reasoning must be defensible:

1. **Different data cadence.** The SIS and ERP hold state data — stable, low frequency (enrollment, outstanding balance). The LMS produces behavioural data — high frequency, high volume (every login, every submission, every forum post). Mixing them means one system's load profile degrades the other.
2. **Different nature of the data.** Financial status is an official fact; LMS activity is a **signal**. The first is queried to inform, the second is queried to infer. Different consumption patterns deserve different contracts.
3. **Fidelity to the real institutional landscape.** At Icesi the LMS is a third-party system with its own lifecycle and its own API. Modelling it as an independent service is more honest than pretending it is an ERP module.

There is also a demonstration benefit: with two source services instead of one, `support-service` genuinely **orchestrates** synchronous calls to multiple sources and composes a decision from all of them. That is the architecturally interesting behaviour.

---

### 5. Declared assumptions

Each of these is a deliberate scope simplification, not a production recommendation. Declaring them is worth more than hiding them.

1. **Single database instance, separate schemas.** One PostgreSQL container with schemas `auth`, `core`, `lms`, `support` and `audit`, and **one database user per service** with permissions restricted to its own schema. Logical isolation, not physical. Production would use one instance per service.
2. **SIS, ERP and LMS are simulated.** `core-service` and `lms-service` are not adapters over real systems; they are simulations that expose the contract the real systems would expose. In production both would consume the institutional **integration platform** (ESB/iPaaS), never the legacy systems point to point.
3. **The integration platform is not built.** It appears in the architecture diagram and its role is explained — protocol translation, throttling towards legacy systems, single diagnostic boundary, audited network egress — but no code is written for it.
4. **Custom SSO instead of the institutional IdP.** It exposes **the same contract** the real IdP would expose (JWKS, role claims). Replacing it with Identity Platform or the Icesi SSO changes one configuration value: the JWKS URL.
5. **Service-to-service authentication is simulated locally.** In the cloud this is a Google-signed ID token whose audience is the target service. Locally it is a JWT signed by the caller with the same claim structure, behind the same interface. Domain code cannot tell the difference.
6. **Domain events are persisted, not published.** They are written to an `outbox` table with the exact payload the real message would carry. Stage 2 only adds a publisher that drains that table.
7. **Seed data, not migration.**

---

### 6. Audit and logging foundations

This is not a final phase. It is a **cross-cutting decision taken before the first endpoint is written**, because retrofitting auditability onto a finished system is exactly the kind of debt that is expensive to repay.

#### Three distinct records, with different owners and destinations

**1. Operational log.** For diagnosing the system. Structured JSON from day one — never plain text — written to `stdout`. Every line carries `timestamp`, `level`, `service`, `traceId`, `spanId`, `requestId`, `userId`, `message`. It goes to `stdout` because that is exactly how Cloud Logging will pick it up in stage 2 without a single code change.

**2. Application audit trail.** Answers *who accessed which data, about which student, when, and under what authorization relationship*. This is a business record, not an infrastructure one. It lives in its own table, in its own schema (`audit`), **append-only** — the application database users are granted `INSERT` and `SELECT` but never `UPDATE` or `DELETE`.

**3. Security event log.** Successful login, failed login, refresh, detected token reuse, session revocation. Stored alongside the audit trail but distinguished by type, because its consumer is different.

#### Correlation

Every request entering through the gateway receives an `X-Request-Id` (or the incoming one is honoured). That id propagates to all downstream services through headers and is injected into the logging MDC. **Any log line from any service must be traceable back to the user request that caused it.** Without this, distributed tracing in stage 2 is worthless, because there is nothing to correlate against.

Micrometer Tracing with W3C `traceparent` propagation is wired in from the start, even though no collector runs locally. The instrumentation is in place; stage 2 only turns on an exporter.

#### Audit table

```sql
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
    details              JSONB                   -- extra context; never sensitive values in clear text
);

CREATE INDEX idx_audit_record_request_id ON audit.audit_record (request_id);
CREATE INDEX idx_audit_record_subject    ON audit.audit_record (subject_type, subject_id, occurred_at DESC);
```

`authorization_basis` is what makes this table genuinely useful. Recording *"advisor X viewed student Y"* is weak. Recording *"…because they held an active assignment"* is what answers an improper-access complaint months later.

#### How records are written

An `@Audited` annotation on service methods that touch sensitive data, intercepted by an aspect that builds the record from the request identity context. **Denied accesses are audited too** — they are the most important ones.

```java
@Audited(action = "READ_FINANCIAL_STATUS", subjectType = "STUDENT")
public FinancialStatus findFinancialStatus(String studentId) { ... }
```

#### Shared module

All of the above lives in a `common` module shared by the five services: JSON logging configuration, correlation filter, identity context, audit aspect and audit writer. It is built in Phase 0, before any domain service.

---

### 7. Engineering standards

These apply to every module. They are not decoration: a reviewer will read the code, and consistency is the cheapest signal of quality available.

#### Language and naming

- **English everywhere**: class names, methods, variables, database tables and columns, API paths, JSON fields, log messages, commit messages, branch names, comments.
- Classes are nouns (`AlertGenerator`), methods are verbs (`generateAlert`), booleans read as predicates (`isActive`, `hasActiveAssignment`).
- No abbreviations except universally understood ones (`id`, `url`, `dto`).
- Database objects use `snake_case`; Java uses `camelCase`; JSON payloads use `camelCase`; URL paths use `kebab-case`.
- Avoid reserved words as table names — hence `app_user` and `auth_session` rather than `user` and `session`.

#### Package structure (ports and adapters, applied lightly)

```
co.edu.icesi.student360.<service>
├── api            REST controllers, request/response DTOs, exception handlers
├── domain
│   ├── model      entities and value objects
│   ├── port       outbound interfaces (repositories, external clients, event publisher)
│   └── service    business logic — no framework annotations beyond @Service
└── infrastructure
    ├── persistence  JPA implementations of repository ports
    ├── client       Feign implementations of external client ports
    ├── security     filters, identity context, token providers
    └── config       Spring configuration classes
```

The rule that gives this structure its value: **`domain` depends on nothing outward**. Business logic never imports a JPA annotation, a Feign client or a Google SDK class. That is precisely what makes the stage 1 → stage 2 migration a matter of swapping `infrastructure` implementations.

#### Java and Spring practices

- **Constructor injection only.** No `@Autowired` on fields — it hides dependencies and blocks immutability.
- **Immutable DTOs as `record`s.** Never expose JPA entities through the API; map explicitly, with MapStruct or a hand-written mapper.
- **Bean Validation** (`@NotNull`, `@Email`, `@Size`) on every inbound DTO, validated at the controller boundary with `@Valid`.
- **Consistent error handling** through a `@RestControllerAdvice` returning RFC 7807 `ProblemDetail`. Error responses never leak stack traces, SQL, or internal class names.
- **Custom domain exceptions** (`StudentNotFoundException`, `AccessDeniedForStudentException`) rather than generic `RuntimeException`.
- **`@Transactional` on service methods, never on controllers**, and read-only where applicable (`@Transactional(readOnly = true)`).
- **Never log tokens, passwords, password hashes, or wellbeing free-text comments.** A log line containing a JWT is a credential leak.
- **`Optional` for possibly-absent return values**; never as a parameter or a field.
- **Lombok is optional**; if used, restrict it to `@RequiredArgsConstructor`, `@Getter` and `@Slf4j`. Avoid `@Data` on entities — it generates `equals`/`hashCode` that break JPA identity semantics.

#### Database

- **Flyway for every schema change**, no exceptions and no `ddl-auto` beyond `validate`.
- Migration naming: `V1__create_auth_tables.sql`, `V2__seed_reference_data.sql`. Migrations are immutable once committed.
- Explicit foreign keys, explicit `NOT NULL`, explicit indexes on every column used in a `WHERE` or a join.
- Timestamps are always `TIMESTAMPTZ`, always stored in UTC.

#### API design

- Plural resource nouns: `/api/core/students/{id}/financial-status`.
- HTTP verbs carry the semantics; no verbs in paths.
- Meaningful status codes: `401` for missing or invalid authentication, `403` for authenticated-but-not-allowed, `404` only when the resource genuinely does not exist. Returning `404` instead of `403` to hide existence is a valid choice — but it must be a deliberate, documented one, applied consistently.
- OpenAPI generated with springdoc, exposed at `/swagger-ui.html` in the `dev` profile only.

#### Configuration and secrets

- Configuration through `application.yml` with profiles (`dev`, `test`). No hardcoded hosts, ports or credentials in code.
- `.env` and `secrets/` are in `.gitignore`. An `.env.example` with placeholder values is committed.
- The JWT private key never enters version control.

#### Testing

- Unit tests for domain services, with mocked ports — fast, no Spring context.
- Integration tests with **Testcontainers** against a real PostgreSQL, at minimum covering refresh token rotation, reuse detection, and fine-grained authorization.
- Test names describe behaviour: `shouldRevokeEntireFamilyWhenRefreshTokenIsReused`.
- No test depends on execution order or on data left behind by another test.

#### Tooling and version control

- Formatting enforced by **Spotless** (google-java-format), style by **Checkstyle**. A build that fails on style is cheaper than a review that argues about it.
- **Conventional Commits**: `feat(auth): add refresh token rotation`, `fix(gateway): propagate request id on error paths`.
- One concern per commit; the message explains *why*, the diff shows *what*.
- Comments explain **why**, never **what**. A comment restating the code is noise; a comment explaining a non-obvious decision is documentation.

---

### 8. Demonstration thread

Everything built must converge on this walkthrough. If a component does not participate in it, its priority drops.

1. A student logs in through the SPA. `auth-service` validates credentials and issues an access token (15 min) and an opaque, rotating refresh token (7 days).
2. The SPA requests her 360° view. The gateway validates the JWT against the `auth-service` JWKS, confirms the `STUDENT` role may reach that route, strips the user token and propagates a signed identity context plus a service token.
3. `core-service` returns academic and financial status, verifying that the `ref` claim matches the requested student id (fine-grained *self* authorization). The access is audited.
4. `lms-service` returns recent engagement: days since last access, on-time and late submission counts, participation.
5. The student submits a low wellbeing entry. `support-service` persists it, pseudonymises the student identifier, and writes the event to the `outbox` table.
6. The risk rule evaluates that entry **together with** signals fetched synchronously from `core-service` and `lms-service`, and produces an alert with a suggested intervention plan.
7. An `ADVISOR` logs in, sees the alert in their inbox and opens the detail. Fine-grained authorization verifies the assignment is active; the access is audited with `authorization_basis = ASSIGNMENT`.
8. The audit table is queried by `request_id`, reconstructing the full path of a single request across four services.
9. **Negative scenario A:** an advisor without an assignment opens the same student → `403`, plus an audit record with `outcome = DENIED`.
10. **Negative scenario B:** an already-consumed refresh token is replayed → the entire token family is revoked, the session dies, and a security record is written. This is the most valuable moment of the demonstration.

---

### 9. Acceptance criteria

The proof of concept succeeds if, live and without touching the database by hand, one can:

- Bring the whole environment up with a single command.
- Log in and show the decoded JWT with its claims.
- Trigger a `403` from the coarse layer (gateway, wrong role for the route).
- Trigger a `403` from the fine layer (right role, wrong student).
- Rotate a refresh token and then trigger reuse detection.
- Walk the full demonstration thread.
- Query the `outbox` table and show the event payload that would be published.
- Query `audit_record` by `request_id` and show the cross-service trail.
- Show JSON logs from two different services sharing the same `traceId`.

---

## PART II — IMPLEMENTATION PLAN (original outline)

The order is not negotiable. The SSO comes first because **nothing else can be genuinely tested without it**: with no valid token, the gateway will not route and services cannot tell who is calling. But the `common` module comes before the SSO, because the SSO itself already needs to write audit records.

---

### Phase 0 — Local environment and shared module

#### 0.1 Repository layout

```
student360/
├── common/                  shared library (logging, audit, identity context, ports)
├── gateway/
├── auth-service/
├── core-service/
├── lms-service/
├── support-service/
├── frontend/
├── infra/
│   ├── docker-compose.yml
│   └── init-db/
│       ├── 01-schemas.sql
│       └── 02-users.sql
├── docs/
└── Makefile
```

#### 0.2 Docker Compose

- `postgres:16` on 5432, with a named volume.
- `adminer` — visual inspection during the demo.
- *(Optional)* `jaeger` all-in-one, if distributed traces should be visible locally. Cheap to add, and it presents well.

Spring Boot services run outside Compose during development (fast restarts, direct IDE debugging) and are containerised at the end.

#### 0.3 Database initialisation

`01-schemas.sql` creates `auth`, `core`, `lms`, `support`, `audit`.

`02-users.sql` creates five database users, one per service. Each gets `USAGE` on its own schema and **nothing else**, plus `INSERT` and `SELECT` on `audit.audit_record` — but no `UPDATE` or `DELETE`, so append-only is a guarantee enforced by the engine rather than a promise made by the code.

This is what turns logical isolation into something real and demonstrable: open a session as the `lms` user, try to read `auth.app_user`, and show it fail.

#### 0.4 The `common` module

1. Logback configuration with a JSON encoder (`logstash-logback-encoder`).
2. `CorrelationFilter` — generates or propagates `X-Request-Id`, populates the MDC with `requestId`, `traceId` and `userId`.
3. `IdentityContext` — request-scoped holder for `userId`, `roles` and `externalReference`, populated from the headers injected by the gateway.
4. `AuditRecord` entity, repository, and `AuditWriter`.
5. `@Audited` annotation and its aspect.
6. `EventPublisher` port with an `OutboxEventPublisher` implementation. The Pub/Sub implementation arrives in stage 2.
7. `ServiceTokenProvider` port with a `LocalServiceTokenProvider` implementation (JWT signed with a dev key, audience = target service). The Google ID token implementation arrives in stage 2.
8. Micrometer Tracing with W3C propagation.
9. `GlobalExceptionHandler` producing RFC 7807 `ProblemDetail` responses.

**Phase gate:** `docker compose up`; connect as the `lms` user and confirm `auth` schema access is denied. Run a throwaway service using `common` and confirm it emits JSON logs carrying `requestId`.

---

### Phase 1 — `auth-service` (the SSO)

Built in full. It is the core of the proof of concept.

#### 1.1 Data model (`auth` schema)

```sql
CREATE TABLE auth.app_user (
    id                  UUID PRIMARY KEY,
    email               TEXT UNIQUE NOT NULL,
    password_hash       TEXT NOT NULL,          -- BCrypt
    full_name           TEXT,
    external_reference  TEXT,                   -- student/advisor id in core-service
    active              BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL
);

CREATE TABLE auth.role (
    id    SERIAL PRIMARY KEY,
    name  TEXT UNIQUE NOT NULL                  -- STUDENT | ADVISOR | ADMIN
);

CREATE TABLE auth.user_role (
    user_id  UUID NOT NULL REFERENCES auth.app_user (id),
    role_id  INT  NOT NULL REFERENCES auth.role (id),
    PRIMARY KEY (user_id, role_id)
);

CREATE TABLE auth.auth_session (
    id                 UUID PRIMARY KEY,        -- identifies the token FAMILY
    user_id            UUID NOT NULL REFERENCES auth.app_user (id),
    created_at         TIMESTAMPTZ NOT NULL,
    revoked_at         TIMESTAMPTZ,
    revocation_reason  TEXT,                    -- LOGOUT | REUSE_DETECTED | EXPIRED
    user_agent         TEXT,
    source_ip          TEXT
);

CREATE TABLE auth.refresh_token (
    id           UUID PRIMARY KEY,
    session_id   UUID NOT NULL REFERENCES auth.auth_session (id),
    token_hash   TEXT NOT NULL,                 -- SHA-256 of the opaque token; never the raw value
    issued_at    TIMESTAMPTZ NOT NULL,
    expires_at   TIMESTAMPTZ NOT NULL,
    used_at      TIMESTAMPTZ,
    replaced_by  UUID REFERENCES auth.refresh_token (id)
);

CREATE UNIQUE INDEX idx_refresh_token_hash ON auth.refresh_token (token_hash);
```

**Key decision to be able to explain:** the refresh token is **opaque** (high-entropy random value), not a JWT, and is stored hashed. If the database leaks, the stolen tokens are useless. The access token *is* a JWT, because it must be verifiable without a database round trip.

#### 1.2 Signing keys

- Generate one RSA 2048 key pair, once.
- Locally: private key in `secrets/jwt-private.pem`, git-ignored, referenced by environment variable. In stage 2 it moves to Secret Manager — the code does not change, only the value source.
- Assign an explicit `kid`. Even with a single key, the `kid` is what allows rotation later without breaking anything.

#### 1.3 Endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/auth/login` | Credentials → access + refresh token. Creates the session (family). |
| `POST` | `/api/auth/refresh` | Refresh token → new pair. **Rotates**: the previous one is invalidated. |
| `POST` | `/api/auth/logout` | Revokes the whole family. |
| `GET` | `/.well-known/jwks.json` | Public key in JWKS format. Unauthenticated. |
| `GET` | `/api/auth/me` | Current user profile from the token. |

#### 1.4 Access token payload

```json
{
  "iss": "http://localhost:8081",
  "sub": "<user uuid>",
  "aud": "student360-api",
  "exp": "<iat + 15 minutes>",
  "iat": "<...>",
  "jti": "<unique id, used for tracing and audit>",
  "roles": ["STUDENT"],
  "ref": "<externalReference: student id in core-service>"
}
```

The `ref` claim enables fine-grained authorization downstream without calling back to the SSO on every request. Its cost — an assignment change is not reflected until the token expires — is acceptable at a 15-minute lifetime, and the answer should be ready in case it is challenged.

#### 1.5 Rotation and reuse detection

This algorithm should be explainable from memory:

1. A refresh token arrives. It is hashed and looked up.
2. **Not found** → `401`.
3. **Found and `used_at` is not null** → **reuse detected**. Set `auth_session.revoked_at` with reason `REUSE_DETECTED`, invalidate every token in the family, write a `SECURITY` audit record, respond `401`.
4. **Session already revoked** → `401`.
5. **Token expired** → `401`.
6. **Valid** → set `used_at = now()`, issue a new pair, link `replaced_by`, return.

**Why the whole family is revoked:** if a consumed token reappears, either the attacker used it and the legitimate user arrived after, or the reverse. The two cases are indistinguishable. Killing the whole session is the only safe response: the cost is that the legitimate user re-authenticates; the benefit is that the attacker also loses access.

Steps 2 through 6 must run inside a single transaction with the token row locked (`SELECT ... FOR UPDATE`), otherwise two concurrent refreshes race and one legitimately-issued family gets destroyed.

#### 1.6 Tasks

1. Spring Boot with `web`, `security`, `data-jpa`, `postgresql`, `nimbus-jose-jwt`, Flyway, and the `common` module.
2. Flyway migrations for the `auth` schema.
3. Seed data: 3 students, 2 advisors, 1 admin, with `external_reference` values matching the ids used by `core-service` and `lms-service`.
4. `AuthenticationService` (login, refresh, logout) and `TokenService` (issuance, JWKS).
5. Audit records for every security event, failures included.
6. Rate limiting on `/api/auth/login` — even a simple in-memory counter — so brute force is not trivially available.

**Phase gate:** login returns the pair; the access token verifies against the JWKS; refresh rotates and the old token stops working; reuse revokes the family and leaves an audit record; logout kills the session.

---

### Phase 2 — `gateway`

Depends on phase 1: with no JWKS there is nothing to validate.

1. Spring Boot with `spring-cloud-starter-gateway` (WebFlux) and `oauth2-resource-server`.
2. Point the issuer/JWKS at `http://localhost:8081`. **One configuration line** — which is exactly the point of designing the SSO as a replaceable adapter.
3. Route/role table:
   - `/api/auth/**` → public
   - `/api/core/**` → `STUDENT`, `ADVISOR`, `ADMIN`
   - `/api/lms/**` → `STUDENT`, `ADVISOR`, `ADMIN`
   - `/api/support/students/**` → `STUDENT`, `ADVISOR`
   - `/api/support/advisors/**` → `ADVISOR`, `ADMIN`
4. Identity rewriting filter: strip the user's `Authorization` header, propagate `X-User-Id`, `X-User-Roles`, `X-External-Reference` and `X-Request-Id`, and attach the service token from `ServiceTokenProvider`.
5. CORS restricted to `http://localhost:5173`.
6. Resilience4j circuit breaker on the routes to `core-service` and `lms-service`, with an observable fallback — shut down `lms-service` and the 360° view still answers with academic and financial data, marking the engagement section as unavailable. That partial degradation is a good demonstration moment.

**Phase gate:** no token → `401`. `STUDENT` token on an advisor route → `403`. `lms-service` down → fallback response, circuit opens.

---

### Phase 3 — `core-service`

1. `core` schema via Flyway: `student`, `program`, `enrollment`, `financial_status`.
2. Seed data consistent with `auth`, including **at least one at-risk student** (overdue balance) so the demonstration thread has something to detect.
3. Endpoints:
   - `GET /api/core/students/{id}`
   - `GET /api/core/students/{id}/academic-status`
   - `GET /api/core/students/{id}/financial-status`
4. Inbound service token validation (correct audience).
5. **Fine-grained authorization:** if the caller's role is `STUDENT`, the `ref` claim must equal `{id}`. Otherwise `403` **and an audit record with `outcome = DENIED`**.
6. `@Audited` on financial status access — the most sensitive data this service owns.

**Phase gate:** with a student token, fetch own data successfully; attempt another student's data and receive `403` with its matching audit record.

---

### Phase 4 — `lms-service`

1. `lms` schema via Flyway:

```
course              id, code, name, term
course_enrollment   id, student_reference, course_id, status
assignment          id, course_id, title, type, due_at
submission          id, assignment_id, student_reference, submitted_at, status  -- ON_TIME | LATE | MISSING
access_log          id, student_reference, course_id, occurred_at, access_type
```

2. Seed data producing a clear pattern: one engaged student, one disengaged (no access in over 14 days, late submissions), one in between. **The at-risk student from `core-service` must be the same disengaged student here** — the convergence of signals is what makes the phase 5 rule meaningful.
3. Endpoints:
   - `GET /api/lms/students/{id}/courses`
   - `GET /api/lms/students/{id}/activity?days=30` → accesses, on-time / late / missing submissions
   - `GET /api/lms/students/{id}/signals` → computed summary: `daysSinceLastAccess`, `onTimeSubmissionRate`, `coursesWithoutActivity`
4. Same service token validation, same fine-grained authorization by `ref`, same auditing.

The `/signals` endpoint is deliberate. Rather than having `support-service` pull raw data and compute on its own, the LMS exposes the already-interpreted signal. That keeps learning-domain knowledge inside the service that owns it, and prevents `support-service` from accumulating logic belonging to a domain it does not own.

**Phase gate:** the at-risk student's signals are clearly distinguishable from the engaged student's.

---

### Phase 5 — `support-service`

The orchestrating service, and therefore last among the domain services.

1. `support` schema via Flyway:

```
wellbeing_entry     id, student_pseudonym, level, comment, recorded_at
advisor_assignment  id, advisor_reference, student_reference, valid_from, valid_to
alert               id, student_reference, severity, source, triggering_signals JSONB, generated_at, status
intervention_plan   id, alert_id, type, description, status
support_report      id, alert_id, advisor_reference, content, created_at
outbox_event        id, event_type, payload JSONB, created_at, published_at
```

2. Feign clients for `core-service` and `lms-service`, with `ServiceTokenProvider` injected into the request interceptor and `X-Request-Id` propagated.
3. `POST /api/support/students/{id}/wellbeing-entries`: persists the entry under a **pseudonymised** identifier (the real mapping never leaves this service) and writes the event to `outbox_event`.
4. **A minimal rule engine with one well-argued rule.** For example: low wellbeing entry **and** (more than 14 days without LMS access **or** on-time submission rate below threshold) **and** overdue balance → high-severity alert with a suggested intervention plan. The rule must store **which signals fired it** in `triggering_signals`, so the alert is explainable rather than a black box. One explainable rule is worth more than five opaque ones.
5. `GET /api/support/advisors/me/alerts` — inbox filtered by active assignment.
6. `GET /api/support/advisors/me/alerts/{id}` — detail, with fine-grained authorization by assignment and an audit record carrying `authorization_basis = ASSIGNMENT`.
7. Outbox events: `WELLBEING_ENTRY_RECORDED`, `ALERT_GENERATED`, `INTERVENTION_PLAN_CREATED`, each with the exact payload that would go to Pub/Sub.

**Phase gate:** record a low wellbeing entry for the at-risk student and watch the alert appear in the assigned advisor's inbox — and not in the other advisor's. Confirm `triggering_signals` explains why it fired.

---

### Phase 6 — Minimal frontend

1. React + Vite SPA with four screens: login, 360° view, wellbeing entry, advisor inbox.
2. Access token held in memory; refresh token in an `HttpOnly`, `Secure`, `SameSite=Strict` cookie.
3. HTTP interceptor: on `401`, exactly one refresh attempt and one retry of the original request; if the refresh fails, redirect to login. Concurrent 401s must share a single in-flight refresh promise, or the second one triggers false reuse detection.
4. No heavy design libraries. The UI is evidence of the flow, not the deliverable.

**Phase gate:** leave the session idle past 15 minutes and confirm the refresh happens transparently.

---

### Phase 7 — End-to-end closure and stage 2 readiness

1. A Postman collection or `curl` script executing the full demonstration thread, both negative scenarios included.
2. Demonstration query: `SELECT * FROM audit.audit_record WHERE request_id = ? ORDER BY occurred_at` — showing one request's path across four services.
3. Testcontainers integration tests covering, at minimum, refresh token rotation, reuse detection and fine-grained authorization. Those are the two places where a bug would be most expensive.
4. `Makefile` with `make up`, `make seed`, `make demo`, `make test`.
5. README containing the assumptions from section 5 and a **"what changes in stage 2"** section listing the interfaces whose implementation swaps: `EventPublisher` → Pub/Sub, `ServiceTokenProvider` → Google ID token, secrets → Secret Manager, `stdout` → Cloud Logging, tracing exporter → Cloud Trace, `outbox_event` → BigQuery via native subscription. That list is the evidence that stage 1 was built with stage 2 in mind.

---

### Cut order under time pressure

From first sacrificed to last:

1. Local Jaeger (instrumentation stays, only visualisation goes).
2. Testcontainers tests.
3. Demonstrated circuit breaker (configuration stays).
4. Frontend screens beyond login and the 360° view.
5. Additional rules in the alert engine.
6. `lms-service` endpoints beyond `/signals`.

**Never sacrificed:** refresh token rotation with reuse detection, two-layer authorization, `support-service` orchestrating both `core-service` and `lms-service`, and the audit table with `request_id` correlation. Those four *are* the proof of concept.
