# Student 360° View — Implementation Plan (stage 1, multi-repository)

Derived from [context.md](context.md). That document fixes *what* and *why*; this one fixes
*in which repository, in which order, in which commits, and how each step is proven*.

## Status

| Phase | State | Evidence |
|---|---|---|
| 0.A infra | **done** (2026-08-30) | `make check-isolation` → PASSED |
| 0.B common | **done** (2026-08-30) | `mvn verify` 17 tests; `FoundationsIntegrationTest` |
| 1 auth-service | **done** (2026-08-30) | `mvn verify` 10 tests; `scripts/demo/phase1-sso.sh` → PASSED |
| 2 gateway | **done** (2026-08-30) | `mvn verify` 6 tests; `scripts/demo/phase2-gateway.sh` → PASSED; gateway + SSO log lines share `traceId` |
| 3 core-service | **done** (2026-08-30) | `mvn verify` 6 tests (self 200/SELF, other student 403/DENIED, staff STAFF_ROLE, 401 without service token) |
| 4 lms-service | **done** (2026-08-30) | `mvn verify` 10 tests; S-1003 signals 21 d / 0.22 / 2 idle courses vs S-1001 1 d / 1.00 / 0 |
| 5 support-service | **done** (2026-08-30) | `mvn verify` 11 tests; HIGH alert with 4 fired conditions, inbox by assignment, ASSIGNMENT/DENIED audit, 3 outbox envelopes |
| 6 frontend | **done** (2026-08-30) | `npm test` 3 (single in-flight refresh), `npm run build` + lint clean; login / 360° view / wellbeing / inbox + detail |
| 7 closure | **done** (2026-08-30) | `make up-containers` (Dockerfile per service) + `make demo` → full thread PASSED against the containerised stack; `make up-all` for local processes; README assumptions + stage 2 swap list |

Open items still requiring an org decision are in §8 (GitHub Packages read token for service CI, branch protection). The SPA was verified by build + unit tests, not yet clicked through against the live gateway.

Deviations from the plan as first written: the commit convention is enforced by **lefthook** locally, not by a CI workflow (Actions minutes); `common` gained `AuditTrail.recordAs(actor, …)` for the SSO; Phase 1 commits 6–9 were delivered as two commits because `AuthenticationService` is one unit.

## 0. Repository map

Every service is its own repository because each becomes an independent Cloud Run deployable in
stage 2 (own Dockerfile, own build trigger, own revision history). Locally, all repositories are
cloned as siblings under one folder; `student360-infra` orchestrates them.

| Repository | Kind | Depends on | Port | Schema |
|---|---|---|---|---|
| `.github` | org defaults | — | — | — |
| `student360-infra` | docs, compose, init-db, Makefile, demo scripts | — | — | creates all schemas + `audit.audit_record` |
| `student360-common` | Maven library `co.edu.icesi.student360:student360-common` | — | — | — |
| `student360-auth-service` | Spring Boot | common | 8081 | `auth` |
| `student360-gateway` | Spring Cloud Gateway | common (service token only) | 8080 | — |
| `student360-core-service` | Spring Boot | common | 8082 | `core` |
| `student360-lms-service` | Spring Boot | common | 8083 | `lms` |
| `student360-support-service` | Spring Boot | common, core-service API, lms-service API | 8084 | `support` |
| `student360-frontend` | React + Vite | gateway API | 5173 | — |

### 0.1 How `common` is shared across repositories

`student360-common` is a plain Maven library. Two resolution paths, same coordinates:

* **Local development:** `make build-common` in `student360-infra` runs `mvn install` in the
  sibling checkout; services resolve it from `~/.m2`.
* **CI / stage 2 builds:** `student360-common` publishes to GitHub Packages on every tag `v*`.
  Service repositories declare that repository in their `pom.xml` and read it with a token that
  has `read:packages` (one-time org secret `PACKAGES_READ_TOKEN`; see §8 open items).

Services pin `<student360-common.version>`; bumping it is an explicit `build(deps)` commit, so a
change in `common` never silently alters a service.

### 0.2 Cross-repository conventions (fixed now, applied everywhere)

* Java 21, Spring Boot 3.5.16, Spring Cloud 2025.0.3, Maven. Group id `co.edu.icesi.student360`.
* Package root `co.edu.icesi.student360.<service>` with `api / domain{model,port,service} / infrastructure{persistence,client,security,config}`.
* Every service honours `PORT` (Cloud Run contract) with the default from the table above.
* Profiles: `dev` (local, Swagger on), `test` (Testcontainers).
* Spotless (google-java-format) + Checkstyle in every Java repo; `mvn verify` fails on style.
* Flyway owns each service's schema. The `audit` schema is owned by `student360-infra`
  (init-db), never by a service migration — no service may alter the audit table.
* Headers propagated by the gateway: `X-Request-Id`, `X-User-Id`, `X-User-Roles`,
  `X-External-Reference`, plus `Authorization: Bearer <service token>` and W3C `traceparent`.
* Commit convention and PR flow: org [CONTRIBUTING](https://github.com/visionEAE/.github/blob/main/CONTRIBUTING.md).
  Scopes used in this project: `api`, `domain`, `db`, `persistence`, `client`, `security`,
  `config`, `logging`, `audit`, `outbox`, `docker`, `make`, `deps`, `ci`.

### 0.3 Delivery unit

One **branch → PR → rebase-merge** per phase gate (or per self-contained functionality when a
phase spans two repositories). The PR description carries the gate evidence (commands + output).
Cut order under time pressure is the one in `context.md`; the four non-negotiables are refresh
rotation with reuse detection, two-layer authorization, support orchestrating core + lms, and the
audit trail correlated by `request_id`.

---

## Phase 0 — Local environment and shared module

### 0.A `student360-infra` — branch `feat/local-environment`

| # | Commit | Content |
|---|---|---|
| 1 | `docs: add student 360 context document` | `docs/context.md` |
| 2 | `docs: add implementation plan` | this file |
| 3 | `feat(docker): add postgres and adminer compose stack` | `infra/docker-compose.yml` (postgres:16 named volume, adminer on 8090), `.env.example` |
| 4 | `feat(db): create schemas, per-service users and append-only audit table` | `init-db/01-schemas.sql`, `02-users.sql`, `03-audit.sql` — each user: `USAGE`+`CREATE` on own schema only, `INSERT`+`SELECT` on `audit.audit_record`, no `UPDATE`/`DELETE` |
| 5 | `feat(make): add orchestration targets for the sibling repositories` | `make up/down/psql`, `make clone`, `make build-common`, `make build-all`, `make run-<service>`, `make keys`, `make check-isolation` |

**Gate 0.A (scripted as `make check-isolation`):** `SELECT * FROM auth.app_user` as `lms_user`
→ `permission denied for schema auth`; `DELETE FROM audit.audit_record` as any service user →
`permission denied`.

### 0.B `student360-common` — branch `feat/shared-foundations`

| # | Commit | Content |
|---|---|---|
| 1 | `build: add maven library skeleton with spotless and checkstyle` | `pom.xml` (packaging jar, Boot BOM import, optional starters), `checkstyle.xml`, GitHub Packages `distributionManagement` |
| 2 | `feat(logging): emit structured json logs to stdout` | `logback-spring.xml` (logstash encoder) with `service`, `traceId`, `spanId`, `requestId`, `userId` fields; MDC keys constants |
| 3 | `feat(logging): add correlation filter honouring x-request-id` | `CorrelationFilter` — generate/propagate id, MDC population, echo header on response |
| 4 | `feat(security): add identity context populated from gateway headers` | `Identity` record, `IdentityContext` (request-scoped holder), `IdentityHeaderFilter` |
| 5 | `feat(security): add service token provider and validator ports with local jwt adapters` | `ServiceTokenProvider`/`ServiceTokenValidator` ports; `LocalServiceTokenProvider` (HS256 shared dev secret, `aud` = target service, `iss` = caller); `ServiceTokenFilter` rejecting wrong audience with 401 |
| 6 | `feat(audit): add audit record writer backed by the shared audit table` | `AuditRecord` model, `AuditWriter` port, `JdbcAuditWriter` (plain `JdbcTemplate`, `INSERT` only, `REQUIRES_NEW` so a denied request still leaves its record) |
| 7 | `feat(audit): add @Audited annotation and aspect recording allowed and denied outcomes` | `@Audited(action, subjectType, subjectIdParam)`, `AuditAspect` — writes `ALLOWED` on return, `DENIED` when an `AccessDenied*` exception escapes, `authorization_basis` from a thread-bound `AuthorizationDecision` |
| 8 | `feat(outbox): add event publisher port with outbox implementation` | `DomainEvent`, `EventPublisher` port, `OutboxEventPublisher` (writes to `<schema>.outbox_event` via `JdbcTemplate`, table name configurable) |
| 9 | `feat(api): add rfc 7807 global exception handler` | `GlobalExceptionHandler` → `ProblemDetail`; domain base exceptions `NotFoundException`, `AccessDeniedForSubjectException`, `AuthenticationFailedException` |
| 10 | `feat(config): add tracing and auto-configuration entry point` | Micrometer Tracing (W3C propagation, no exporter), `Student360CommonAutoConfiguration` registered in `AutoConfiguration.imports` so services need zero wiring |
| 11 | `test: verify correlation, identity, audit aspect and outbox with a minimal boot context` | Slice tests + Testcontainers test proving an audit row lands for ALLOWED and DENIED |
| 12 | `ci: build, verify and publish the library to github packages on tags` | workflow: `mvn verify` on PR; publish on `v*` |

**Gate 0.B:** `mvn verify` green; the Testcontainers test shows a JSON log line with `requestId`
and an `audit_record` row for a DENIED call. Tag `v0.1.0`.

---

## Phase 1 — `student360-auth-service` — branch `feat/sso`

| # | Commit | Content |
|---|---|---|
| 1 | `build: add spring boot service skeleton depending on student360-common` | `pom.xml`, `application.yml` (`dev`/`test`), `PORT` binding, Swagger in `dev` |
| 2 | `feat(db): create auth schema tables` | `V1__create_auth_tables.sql` (`app_user`, `role`, `user_role`, `auth_session`, `refresh_token`, unique index on `token_hash`) |
| 3 | `feat(db): seed roles and demo users` | `V2__seed_reference_data.sql` — 3 students, 2 advisors, 1 admin; `external_reference` = ids reused by core/lms (`S-1001`…, `A-2001`…) |
| 4 | `feat(security): load rsa signing key with explicit kid and expose jwks` | `SigningKeyProvider` (PEM path from env), `JwksController` `/.well-known/jwks.json` |
| 5 | `feat(security): issue access tokens with roles and ref claims` | `TokenService` (nimbus RS256, 15 min, `iss/aud/jti/roles/ref`) |
| 6 | `feat(domain): authenticate credentials and open a token family` | `AuthenticationService.login` — BCrypt check, session (family) creation, opaque refresh token (256-bit random, SHA-256 stored) |
| 7 | `feat(domain): rotate refresh tokens inside a locked transaction` | `refresh` — `SELECT … FOR UPDATE`, `used_at`, `replaced_by`, new pair |
| 8 | `feat(security): revoke the whole family when a consumed refresh token is replayed` | reuse detection → `revocation_reason = REUSE_DETECTED`, `SECURITY` audit record, 401 |
| 9 | `feat(domain): revoke the session on logout` | `logout` → `revoked_at`, reason `LOGOUT` |
| 10 | `feat(api): expose login, refresh, logout and me endpoints` | controllers, request/response records, validation, refresh token as `HttpOnly` cookie **and** in body (frontend uses cookie; demo scripts use body) |
| 11 | `feat(audit): record every security event including failures` | `LOGIN_SUCCEEDED`, `LOGIN_FAILED`, `TOKEN_REFRESHED`, `REFRESH_TOKEN_REUSED`, `SESSION_REVOKED` |
| 12 | `feat(security): rate limit login attempts per email and source ip` | in-memory sliding window, 429 with `Retry-After` |
| 13 | `test(security): cover rotation, reuse detection and family revocation` | Testcontainers: `shouldRotateRefreshTokenAndInvalidatePrevious`, `shouldRevokeEntireFamilyWhenRefreshTokenIsReused`, `shouldRejectRefreshAfterLogout`, `shouldNotDestroyFamilyOnConcurrentRefresh` |
| 14 | `ci: build and verify on pull requests` | workflow with Testcontainers (Docker available on ubuntu runners) |

**Gate 1 (scripted as `student360-infra/scripts/demo/phase1-sso.sh`):** login returns the pair;
the access token verifies against the JWKS (`jwt` decode + signature check); refresh rotates and
the old token → 401; replaying it → family revoked + `audit_record` with `action =
REFRESH_TOKEN_REUSED`; logout → subsequent refresh 401.

---

## Phase 2 — `student360-gateway` — branch `feat/entry-point`

| # | Commit | Content |
|---|---|---|
| 1 | `build: add spring cloud gateway skeleton` | WebFlux gateway, `oauth2-resource-server`, `PORT` |
| 2 | `feat(security): validate access tokens against the auth-service jwks` | one property: `spring.security.oauth2.resourceserver.jwt.jwk-set-uri` (+ issuer, audience validator) |
| 3 | `feat(security): enforce route to role authorization` | route/role table from `context.md` §Phase 2 → 401 / 403 |
| 4 | `feat(security): rewrite identity headers and attach a service token` | global filter: strip `Authorization`, add `X-User-Id`, `X-User-Roles`, `X-External-Reference`, `X-Request-Id`, service token from `common` |
| 5 | `feat(config): restrict cors to the local spa origin` | `http://localhost:5173` |
| 6 | `feat(config): add circuit breakers with observable fallbacks for core and lms` | Resilience4j; fallback returns `503` problem detail with `"section": "engagement"` |
| 7 | `test(security): cover 401, 403 and header rewriting` | WebTestClient with a locally signed test JWKS |
| 8 | `ci: build and verify on pull requests` | |

**Gate 2:** no token → 401; `STUDENT` token on `/api/support/advisors/**` → 403; `lms-service`
down → fallback body, circuit state `OPEN` visible on `/actuator/circuitbreakers`.

---

## Phase 3 — `student360-core-service` — branch `feat/student-records`

| # | Commit | Content |
|---|---|---|
| 1 | `build: add spring boot service skeleton depending on student360-common` | |
| 2 | `feat(db): create core schema tables` | `student`, `program`, `enrollment`, `financial_status` |
| 3 | `feat(db): seed students consistent with auth references including one at risk` | `S-1003` has an overdue balance |
| 4 | `feat(security): validate inbound service tokens by audience` | from `common`, audience `core-service` |
| 5 | `feat(security): enforce self authorization for the student role` | `StudentAccessPolicy` — `ref == {id}` else `AccessDeniedForSubjectException` (basis `SELF` / `ADMIN_ROLE` / `NONE`) |
| 6 | `feat(api): expose student, academic status and financial status endpoints` | |
| 7 | `feat(audit): audit financial status reads with allowed and denied outcomes` | `@Audited(action = "READ_FINANCIAL_STATUS", subjectType = "STUDENT")` |
| 8 | `test(security): cover self authorization and its audit trail` | Testcontainers |
| 9 | `ci: build and verify on pull requests` | |

**Gate 3:** own data 200; another student's data 403 + `audit_record(outcome = DENIED,
authorization_basis = NONE)`.

---

## Phase 4 — `student360-lms-service` — branch `feat/engagement-signals`

| # | Commit | Content |
|---|---|---|
| 1 | `build: add spring boot service skeleton depending on student360-common` | |
| 2 | `feat(db): create lms schema tables` | `course`, `course_enrollment`, `assignment`, `submission`, `access_log` |
| 3 | `feat(db): seed engaged, intermediate and disengaged activity patterns` | `S-1003` disengaged (>14 days no access, late submissions) |
| 4 | `feat(security): validate service tokens and enforce self authorization` | same policy as core |
| 5 | `feat(domain): compute engagement signals` | `daysSinceLastAccess`, `onTimeSubmissionRate`, `coursesWithoutActivity` |
| 6 | `feat(api): expose courses, activity and signals endpoints` | |
| 7 | `feat(audit): audit signal reads` | `READ_ENGAGEMENT_SIGNALS` |
| 8 | `test(domain): cover signal computation on the seeded patterns` | |
| 9 | `ci: build and verify on pull requests` | |

**Gate 4:** `/signals` for `S-1003` vs `S-1001` are clearly different.

---

## Phase 5 — `student360-support-service` — branch `feat/risk-alerts`

| # | Commit | Content |
|---|---|---|
| 1 | `build: add spring boot service skeleton depending on student360-common` | + OpenFeign |
| 2 | `feat(db): create support schema tables including the outbox` | `wellbeing_entry`, `advisor_assignment`, `alert`, `intervention_plan`, `support_report`, `outbox_event` |
| 3 | `feat(db): seed advisor assignments` | `A-2001` → `S-1003` active; `A-2002` unassigned |
| 4 | `feat(client): add feign clients for core and lms carrying service token and request id` | `CoreServiceClient`, `LmsServiceClient` ports + Feign adapters, interceptor |
| 5 | `feat(domain): record pseudonymised wellbeing entries and emit outbox events` | HMAC pseudonym, `WELLBEING_ENTRY_RECORDED` |
| 6 | `feat(domain): evaluate the convergent risk rule and generate explainable alerts` | rule: low wellbeing ∧ (daysSinceLastAccess > 14 ∨ onTimeRate < 0.6) ∧ overdue balance → HIGH alert; `triggering_signals` JSONB; `ALERT_GENERATED`, `INTERVENTION_PLAN_CREATED` |
| 7 | `feat(security): authorize advisor access by active assignment` | `AssignmentAccessPolicy` → basis `ASSIGNMENT` |
| 8 | `feat(api): expose wellbeing entry and advisor inbox endpoints` | |
| 9 | `feat(audit): audit alert detail access` | `READ_ALERT_DETAIL` |
| 10 | `test(domain): cover the risk rule with mocked source clients` | unit tests, no Spring |
| 11 | `test(security): cover assignment authorization and its audit trail` | Testcontainers + WireMock for core/lms |
| 12 | `ci: build and verify on pull requests` | |

**Gate 5:** low entry for `S-1003` → alert in `A-2001` inbox, absent from `A-2002`;
`triggering_signals` lists the three fired signals; three rows in `outbox_event`.

---

## Phase 6 — `student360-frontend` — branch `feat/spa`

| # | Commit | Content |
|---|---|---|
| 1 | `build: scaffold react and vite application` | |
| 2 | `feat(auth): keep the access token in memory and refresh through the cookie` | single in-flight refresh promise, one retry on 401 |
| 3 | `feat(views): add login and 360 view screens` | |
| 4 | `feat(views): add wellbeing entry and advisor inbox screens` | |
| 5 | `ci: lint and build on pull requests` | |

**Gate 6:** idle past 15 minutes → transparent refresh; two concurrent 401s → one refresh call.

---

## Phase 7 — closure — `student360-infra` branch `feat/demo-and-readiness`

| # | Commit | Content |
|---|---|---|
| 1 | `feat(demo): script the full demonstration thread with both negative scenarios` | `scripts/demo/run.sh` using `curl` + `jq`; prints the `request_id` to query |
| 2 | `feat(demo): add audit and outbox inspection queries` | `scripts/demo/audit-trail.sql`, `outbox.sql` |
| 3 | `feat(docker): add compose profile running every service as a container` | Dockerfiles live in each service repo; compose references the sibling build contexts |
| 4 | `docs: describe assumptions and what changes in stage 2` | README section mapping each port to its stage 2 adapter |

**Gate 7 = acceptance criteria in `context.md` §9.**

---

## 8. Open items requiring an org decision

1. **`PACKAGES_READ_TOKEN` org secret** (PAT with `read:packages`) so service CI can resolve
   `student360-common` from GitHub Packages. Until it exists, service CI checks out
   `student360-common` and installs it locally — slower but secret-free.
2. **Branch protection on `main`** for every repo (require PR + `commit-convention` +
   `build` checks). Requires the `admin:org` scope or the web UI.
3. Whether the org `.github` repository should be public (needed only for a public org profile).

## 9. Stage 2 swap list (kept current as ports are created)

| Port (in `common` or service) | Stage 1 adapter | Stage 2 adapter |
|---|---|---|
| `EventPublisher` | `OutboxEventPublisher` | Pub/Sub publisher draining the outbox |
| `ServiceTokenProvider` / `ServiceTokenValidator` | `Local*` (HS256 shared secret) | Google ID token (audience = Cloud Run URL) |
| `SigningKeyProvider` | PEM file path | Secret Manager |
| JWKS location (gateway) | `http://localhost:8081/.well-known/jwks.json` | institutional IdP JWKS URL |
| Logging sink | `stdout` JSON | Cloud Logging (unchanged code) |
| Tracing exporter | none | Cloud Trace |
| `outbox_event` consumer | none | BigQuery via Pub/Sub native subscription |
| Database | Docker PostgreSQL | Cloud SQL via Auth Proxy (JDBC URL only) |
