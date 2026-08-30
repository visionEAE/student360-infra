# student360-infra

Documentation, local infrastructure and orchestration for **Student 360° View** — an
architectural proof of concept for Universidad Icesi, stage 1 (local).

* **[docs/running-locally.md](docs/running-locally.md) — how to run it locally and how it works. Start here.**
* [docs/stage2-deployment.md](docs/stage2-deployment.md) — stage 2: the GCP deployment, keyless CI/CD and the DWH feed.
* [docs/context.md](docs/context.md) — what the proof of concept is, assumptions, standards, demonstration thread.
* [docs/implementation-plan.md](docs/implementation-plan.md) — repositories, order, commits and phase gates.
* [docs/api-contract-v2.md](docs/api-contract-v2.md) · [docs/network-contract.md](docs/network-contract.md) — the endpoints.
* [docs/gcp-deployment-feasibility.md](docs/gcp-deployment-feasibility.md) — what moving to GCP would take.

The system is split into one repository per service (each a future Cloud Run deployable);
they are expected as siblings of this folder:

```
<folder>/
├── student360-infra/            this repository
├── student360-common/           shared library
├── student360-auth-service/     SSO                      :8081
├── student360-gateway/          entry point              :8080
├── student360-core-service/     SIS + ERP simulation     :8082
├── student360-lms-service/      LMS simulation           :8083
├── student360-support-service/  alerts and interventions :8084
├── student360-network-service/  support network (Neo4j)  :8085
└── student360-frontend/         SPA                      :5173
```

## Single command

```bash
make up-all           # databases + the six services as local processes (needs Java 21, Maven)
make up-containers    # …or the same stack fully containerised from each repo's Dockerfile
make seed-network     # load the showcase support networks into Neo4j
make demo             # the demonstration thread with both negative scenarios
```

## Quick start

```bash
make clone            # clone the sibling repositories that are missing
make hooks            # lefthook commit-message hook + template in every repo (needs: npm i -g lefthook)
make env              # .env from .env.example — edit the placeholders
make keys             # RSA key pair for auth-service (secrets/, git-ignored)
make up               # PostgreSQL 16 + Neo4j 5 + Adminer (http://localhost:8090)
make check-isolation  # phase gate 0.A: schema isolation and append-only audit trail
make build-common     # install the shared library into ~/.m2
make run-auth-service # run a service with the .env loaded
scripts/demo/phase1-sso.sh      # phase gate 1 against the running SSO
scripts/demo/phase2-gateway.sh  # phase gate 2 through the gateway (LOG_DIR=… also checks shared traceId)
make demo             # the full demonstration thread with both negative scenarios (all 6 services running)
```

Conventions for every repository: [visionEAE CONTRIBUTING](https://github.com/visionEAE/.github/blob/main/CONTRIBUTING.md).

## Declared assumptions (stage 1)

Deliberate scope simplifications, not production recommendations — see `docs/context.md` §5.

1. **One PostgreSQL instance, one schema per service**, one database role per service confined to its schema; the audit table is append-only by grant (`make check-isolation` proves both).
2. **SIS, ERP and LMS are simulated** by `core-service` and `lms-service`, exposing the contract the real systems would expose through the institutional integration platform.
3. **The integration platform is not built**; it is a box in the diagram (protocol translation, throttling, single diagnostic boundary, audited egress).
4. **Custom SSO** with the same contract as the institutional IdP (JWKS, role claims); replacing it is one gateway property.
5. **Service-to-service auth is simulated**: an HS256 JWT with the same claim structure as a Google ID token, behind `ServiceTokenProvider`/`ServiceTokenValidator`.
6. **Domain events are persisted, not published**: `support.outbox_event` holds the exact Pub/Sub envelope.
7. **Seed data, not migration.**

## What changes in stage 2 (and what does not)

Every cloud-bound concern is a port with a local adapter; moving to Cloud Run swaps adapters and configuration, never domain code.

| Port / concern | Stage 1 adapter | Stage 2 adapter | Where |
|---|---|---|---|
| `EventPublisher` | `OutboxEventPublisher` | Pub/Sub relay draining `outbox_event` | common → support |
| `ServiceTokenProvider` / `ServiceTokenValidator` | `Local*` (shared HS256 secret) | Google-signed ID token, audience = Cloud Run URL | common |
| `SigningKeyProvider` | `PemSigningKeyProvider` (file path) | Secret Manager | auth-service |
| JWKS location | `AUTH_SERVICE_URL/.well-known/jwks.json` | institutional IdP JWKS | gateway (one property) |
| `LoginAttemptLimiter` | in-memory | shared store | auth-service |
| Logging sink | `stdout` JSON | Cloud Logging — **no code change** | all |
| Tracing exporter | none (W3C propagation already on) | Cloud Trace | all |
| `outbox_event` consumer | none | BigQuery via Pub/Sub native subscription | — |
| Database | Docker PostgreSQL | Cloud SQL through the Auth Proxy (JDBC URL only) | all |
| Runtime | `make up-all` / compose | Cloud Run, one service per repository (`Dockerfile` in each) | all |
