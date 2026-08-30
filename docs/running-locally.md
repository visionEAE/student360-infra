# Running Student 360° locally, and how it works

Everything in stage 1 runs on one machine. This page is the runbook: what to install, how to start
it, how to log in, what is actually happening when you do, and how to look inside it.

The deeper reference lives elsewhere and is linked from here rather than repeated:
[`context.md`](context.md) (what the proof of concept is and why),
[`api-contract-v2.md`](api-contract-v2.md) and [`network-contract.md`](network-contract.md)
(the endpoints), [`implementation-plan.md`](implementation-plan.md) (how it was built),
[`gcp-deployment-feasibility.md`](gcp-deployment-feasibility.md) (what stage 2 would cost).

---

## 1. What you need

| Tool | Used for | Verified with |
|---|---|---|
| **Docker** + Compose v2 | PostgreSQL, Neo4j, and optionally every service | 29.7 / v5.5 |
| **Java 21** + **Maven** | building and running the services | Temurin 21.0.12 / Maven 3.8.7 |
| **Node 20+** + npm | the SPA | Node 22.21 / npm 10.9 |
| `curl`, `jq`, `psql` | only for `make demo` and the phase-gate scripts | curl 8.5, jq 1.7, psql 16 |
| `gh` | only for `make clone` | 2.45 |
| `lefthook` | only for `make hooks` (`npm i -g lefthook`) | 2.1 |

The repositories are **siblings**, one per service, because each one is a separately deployable
Cloud Run unit. Clone them next to each other:

```
<folder>/
├── student360-infra/            ← you are here (docker-compose, Makefile, docs)
├── student360-common/           shared library (audit, identity, service tokens)
├── student360-auth-service/     SSO                        :8081
├── student360-gateway/          entry point                :8080
├── student360-core-service/     SIS + ERP simulation       :8082
├── student360-lms-service/      LMS simulation             :8083
├── student360-support-service/  alerts and interventions   :8084
├── student360-network-service/  support network (Neo4j)    :8085
└── student360-frontend/         SPA                        :5173
```

`make clone` fetches whichever are missing.

---

## 2. Start it

### The short path — everything in containers

```bash
cd student360-infra
make env                # creates .env from .env.example
$EDITOR .env            # ← replace every change-me value (see §2.1)
make keys               # RSA key pair for auth-service, into secrets/ (git-ignored)
make up-containers      # builds all six service images and starts the whole stack
make seed-network       # loads the showcase support networks into Neo4j
```

Then start the SPA, which is the one piece **not** in Compose — you almost always want it in dev
mode with hot reload:

```bash
cd ../student360-frontend
cp .env.example .env    # VITE_GATEWAY_URL=http://localhost:8080
npm install
npm run dev             # http://localhost:5173
```

### The development path — databases in Docker, services as local processes

Use this when you are changing Java code: a service restarts in seconds instead of rebuilding an
image.

```bash
make up                 # PostgreSQL + Neo4j + Adminer only
make build-common       # installs student360-common into ~/.m2 — services will not resolve without it
make up-all             # starts all six services in the background, logs in logs/
make seed-network
```

`make up-all` waits until all six report healthy. To run just one service in the foreground (the
usual loop while working on it):

```bash
make run-support-service
```

`make run-<service>` sources `.env` for you, so credentials live in exactly one file and no service
repo ever holds a copy.

### 2.1 About `.env`

`make env` copies `.env.example`, whose values are all `change-me…` placeholders. Two of them are
not cosmetic:

* `SERVICE_TOKEN_SECRET` — **must be at least 32 bytes** and identical across every service; it is
  the HS256 key services use to prove their identity to each other. A mismatch shows up as `401`
  on every inter-service call.
* `NEO4J_PASSWORD` — **at least 8 characters**, or the Neo4j container refuses to start.

`.env` is git-ignored, as is `secrets/`. Nothing here is a real credential.

---

## 3. Log in

Open <http://localhost:5173>. Every seeded account uses the password **`student360`**.

| Perspective | Email | What it is for |
|---|---|---|
| Student — at risk | `maria.rojas@u.icesi.edu.co` | The main thread: an open high-severity alert, and a deliberately thin support network whose one strong tie is her mother |
| Student — on track | `ana.torres@u.icesi.edu.co` | The contrast: no alert, and a broad, balanced support network |
| Support team | `carlos.mejia@icesi.edu.co` | 6 advisees across a real spread of risk, alert inbox, interventions, reports |
| Support team | `diana.perez@icesi.edu.co` | A second caseload — and the account that is correctly **denied** María Rojas's alert, since she holds no active assignment to her |

These exist only in a disposable local database. The full list is in the
[public overview](https://github.com/visionEAE/.github/blob/main/docs/OVERVIEW.md#9-try-it-yourself--demo-credentials).

---

## 4. How it works

### The shape of a request

Every call from the SPA goes to the gateway and nowhere else. Take the student opening their 360°
view:

```
SPA ──access token──► gateway ──┬── strips the user's token
  :5173                  :8080  ├── validates it against auth-service's JWKS
                                ├── checks the coarse rule: may a STUDENT reach /api/core/**?
                                └── forwards, attaching
                                      • a signed SERVICE token (audience = the target service)
                                      • the caller's identity as headers (user id, roles, ref)
                                      • the request id
                                          │
        ┌───────────────┬─────────────────┼──────────────────┬────────────────┐
        ▼               ▼                 ▼                  ▼                ▼
  core-service     lms-service     support-service     network-service    auth-service
     :8082            :8083            :8084               :8085            :8081
   SIS + ERP        engagement      alerts, plans,     who supports        SSO, token
                     signals         wellbeing         this student         rotation
        │               │                 │                  │
        └── core schema └── lms schema    └── support schema  └── Neo4j + network schema
                     one PostgreSQL, one schema and one role per service
```

Two things are worth understanding because they explain most of the code:

**Authorization is two layers, on purpose.** The gateway answers the coarse question — *may this
role reach this route family?* It cannot answer the fine one, because it does not own the data:
*may **this** advisor see **that** student?* is decided inside the service that holds the record,
which is also where the answer gets audited, with the reason recorded as `SELF`, `ASSIGNMENT`,
`STAFF_ROLE`, `ADMIN_ROLE` or `NONE`. That is why Diana Pérez gets a `403` on María Rojas: the
gateway lets an `ADVISOR` through to `/api/support/advisors/**`, and support-service then finds no
active assignment. See [§3 of the overview](https://github.com/visionEAE/.github/blob/main/docs/OVERVIEW.md).

**support-service composes, the others do not.** It is the only service that calls others
synchronously: recording a wellbeing entry makes it fetch the financial status from core-service
and the engagement signal from lms-service, evaluate the risk rule over all three, and raise an
alert. Everything else answers from its own store. `make demo` prints exactly this happening.

### Where the data lives

| Store | Holds | Migrated by |
|---|---|---|
| PostgreSQL schema `auth` | accounts, sessions, refresh tokens | auth-service (Flyway) |
| `core` | students, programs, enrolment, grades, payments, professors | core-service (Flyway) |
| `lms` | courses, submissions, access logs | lms-service (Flyway) |
| `support` | wellbeing entries, alerts, plans, reports, assignments | support-service (Flyway) |
| `network` | the outbox only — the graph itself is not here | network-service (Flyway) |
| `audit` | the append-only trail, written by every service | **infra** (`init-db/`), never a service |
| **Neo4j** | `Person` nodes and rated `SUPPORTS` edges | `make seed-network` (no Flyway equivalent) |

Each service has its own database role, confined to its own schema. That is not a convention — it
is enforced, and `make check-isolation` proves it by trying the forbidden operations and asserting
they fail.

The `audit` schema is owned by infra rather than by any service, and its grants allow only
`INSERT` and `SELECT`. Nobody can update or delete a record, including the service that wrote it.

### What is deliberately simulated

Stage 1 fakes four things behind interfaces, so stage 2 swaps an adapter rather than rewriting a
domain: the SIS/ERP and the LMS (core-service and lms-service expose the contract the real systems
would), the institutional IdP (auth-service issues the same claim structure and publishes JWKS),
service-to-service auth (an HS256 token shaped like a Google ID token), and message publishing
(domain events are written to `outbox_event` tables holding the exact Pub/Sub envelope, and never
published). [`context.md` §5](context.md) lists all of them with the reasoning.

---

## 5. Look inside it

```bash
make psql                            # psql as superuser
make logs                            # database logs
make logs-all                        # JSON logs of services started by up-all
```

* **Adminer** — <http://localhost:8090> (server `postgres`, user `postgres`, the password from `.env`)
* **Neo4j Browser** — <http://localhost:7474> (user `neo4j`, `NEO4J_PASSWORD` from `.env`).
  The whole graph is small enough to see at once:
  ```cypher
  MATCH (p:Person)-[r:SUPPORTS]->(s:Person {reference: 'S-1003'}) RETURN p, r, s;
  ```

Two queries worth knowing, both used by `make demo`. They are plain `.sql` files, so they need
connection flags — and `audit-trail.sql` takes the request id as a psql variable:

```bash
set -a; . .env; set +a            # POSTGRES_PORT, POSTGRES_PASSWORD
export PGPASSWORD="$POSTGRES_PASSWORD"
PSQL="psql -h localhost -p ${POSTGRES_PORT:-5432} -U postgres -d student360"

# every service that touched ONE request, in order — the point of the correlated trail.
# Any request id works; the SPA sends spa-<uuid>, and make demo uses demo-<time>-<step>.
$PSQL -v request_id='demo-165504-entry' -f scripts/demo/audit-trail.sql

# what stage 2 would have published to Pub/Sub, with the exact envelope
$PSQL -f scripts/demo/outbox.sql
```

To find a request id to pass in:

```bash
$PSQL -c "SELECT DISTINCT request_id FROM audit.audit_record ORDER BY 1 DESC LIMIT 10;"
```

---

## 6. Check that it really works

```bash
make check-isolation   # schema isolation + the append-only audit trail (phase gate 0.A)
make demo              # the full demonstration thread, including both negative cases
make verify-all        # mvn verify in every Java repo (unit + Testcontainers integration tests)
```

`make demo` needs the whole stack running. It walks the thread end to end and asserts at each step
— a student logs in, reads their own record through the gateway, is refused another student's, a
low wellbeing entry converges three risk signals into an alert, the *assigned* advisor opens it
while the unassigned one is refused, and a consumed refresh token is replayed and kills its whole
session family. It finishes with `Demonstration thread: PASSED`.

`make verify-all` runs Testcontainers, so it needs Docker and pulls Postgres and Neo4j images the
first time.

In the frontend repo: `npm run build`, `npm run lint`, `npm run test`.

---

## 7. When it does not start

| Symptom | Cause |
|---|---|
| `NEO4J_PASSWORD is missing a value` on any `docker compose` call | You ran `docker compose` directly instead of through `make`. The Makefile passes `--env-file .env`; a bare call does not. Use the `make` targets. |
| Services 401 each other; nothing works past the gateway | `SERVICE_TOKEN_SECRET` differs between services or is under 32 bytes. It is one value in one `.env`. |
| Neo4j container exits immediately | `NEO4J_PASSWORD` is shorter than 8 characters. |
| `Could not resolve student360-common` | Run `make build-common` — the services resolve it from your local `~/.m2`, and it is not published anywhere. |
| A service starts but every request 500s on the database | The schema was created before that service's migrations existed. `make reset` drops the volume and re-runs `init-db/`, then start again. |
| `make demo` fails at step 1 | The stack is not fully up. Check `make logs-all`, or `curl localhost:8080/actuator/health`. |
| Port already in use | `make down-all` stops services **by port**, so it will not touch unrelated processes. `make down-containers` stops the containerised stack. |
| The graph is empty after `make reset` | `reset` drops the Neo4j volume too. Re-run `make seed-network`. |

Reseeding is always safe: `make seed-network` is idempotent, every write being a `MERGE` on a
stable reference, so running it twice leaves the same graph.

---

## 8. Target reference

| Target | Does |
|---|---|
| `make help` | lists all of these |
| `make clone` | clones missing sibling repositories |
| `make env` / `make keys` | `.env` from the example; RSA key pair into `secrets/` |
| `make up` / `make down` / `make reset` | databases only — start, stop, stop **and drop the volumes** |
| `make up-all` / `make down-all` / `make logs-all` | the six services as local processes |
| `make up-containers` / `make down-containers` | the six services as containers |
| `make run-<service>` | one service in the foreground, `.env` loaded |
| `make build-common` / `make build-all` | install the shared library; build every service |
| `make seed-network` | load the showcase support networks into Neo4j |
| `make demo` / `make check-isolation` / `make verify-all` | the three ways to prove it works |
| `make psql` / `make logs` | a database shell; database logs |
| `make hooks` | lefthook commit-message hook in every repo |
