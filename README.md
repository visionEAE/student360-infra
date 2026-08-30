# student360-infra

Documentation, local infrastructure and orchestration for **Student 360° View** — an
architectural proof of concept for Universidad Icesi, stage 1 (local).

* [docs/context.md](docs/context.md) — what the proof of concept is, assumptions, standards, demonstration thread.
* [docs/implementation-plan.md](docs/implementation-plan.md) — repositories, order, commits and phase gates.

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
└── student360-frontend/         SPA                      :5173
```

## Quick start

```bash
make clone            # clone the sibling repositories that are missing
make hooks            # lefthook commit-message hook + template in every repo (needs: npm i -g lefthook)
make env              # .env from .env.example — edit the placeholders
make keys             # RSA key pair for auth-service (secrets/, git-ignored)
make up               # PostgreSQL 16 + Adminer (http://localhost:8090)
make check-isolation  # phase gate 0.A: schema isolation and append-only audit trail
make build-common     # install the shared library into ~/.m2
make run-auth-service # run a service with the .env loaded
scripts/demo/phase1-sso.sh      # phase gate 1 against the running SSO
scripts/demo/phase2-gateway.sh  # phase gate 2 through the gateway (LOG_DIR=… also checks shared traceId)
make demo             # the full demonstration thread with both negative scenarios (all 5 services running)
```

Conventions for every repository: [visionEAE CONTRIBUTING](https://github.com/visionEAE/.github/blob/main/CONTRIBUTING.md).
