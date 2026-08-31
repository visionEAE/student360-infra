# Stage 2 — deployment on GCP (runbook)

Stage 1 runs everything locally ([running-locally.md](running-locally.md)). Stage 2 puts the same
system on Google Cloud, keyless end to end, with the data-warehouse feed live. This page is the
map of what exists and the exact first-deployment sequence.

## What lives where

| Repo | Holds |
|---|---|
| [`terraform-backend`](https://github.com/visionEAE/terraform-backend) | The irrecoverable half: tf state bucket, Artifact Registry, Secret Manager, the WIF keyless CI identity, the BigQuery dataset |
| [`terraform-core`](https://github.com/visionEAE/terraform-core) | The disposable half: 7 Cloud Run services + the relay job, Cloud SQL (private IP), networking, DWH feed, bastion |
| [`workflows`](https://github.com/visionEAE/workflows) | The reusable CI/CD: verify, content-hash-gated build, digest rollout |
| [`student360-dwh-relay`](https://github.com/visionEAE/student360-dwh-relay) | The Cloud Run job draining the outbox tables into Pub/Sub |

Architecture on GCP, in one paragraph: the SPA (nginx on Cloud Run, `s360-web`) talks only to
`s360-gateway`; gateway, auth and web are public, every other service is **private by IAM** and
callable only by the service accounts listed as its invokers, authenticated with Google-signed ID
tokens (the stage-2 adapters behind the same ports the local HS256 pair used). One Cloud SQL
instance holds the same schemas as local; Neo4j is **AuraDB Free** (external — GCP has no managed
graph); domain events flow outbox → relay job (Cloud Scheduler, every 5 min) → Pub/Sub
`student360-events` → BigQuery subscription → `student360_dwh.outbox_events`. No custom DNS: the
`*.run.app` URLs, TLS included, are the addresses.

## How a deploy works (every service repo)

Push to `main` (or the always-available manual trigger) → the repo's thin `deploy.yml` calls the
reusable workflow, which:

1. Computes a **content hash** over what actually enters the image (sources, pom/lockfile,
   Dockerfile, the exact `student360-common` commit — or the gateway URL, for the SPA) →
   tag `content-<hash>`.
2. If that tag already exists in Artifact Registry, **skips the build** and reuses the digest.
3. Otherwise builds (jar in CI, `provenance: false`) and pushes.
4. Rolls Cloud Run **by digest** — never by tag — and smoke-tests readiness.

Keyless: the job trades GitHub's OIDC token for the deployer's short-lived credentials via
Workload Identity Federation. Everything it consumes is an Actions *variable* written by
`terraform-backend/scripts/github-setup.sh`.

## First deployment, in order

```bash
# 0. prerequisites (manual): GCP project + trial billing; gcloud auth login && gcloud auth
#    application-default login; an AuraDB Free instance (note URI + password).

# 1. wire the project id (both repos: backend.tf literal + tfvars), then
cd terraform-backend
scripts/bootstrap.sh                 # local state → targeted apply → migrate → full apply

# 2. supply the out-of-band secrets (values never touch tf state)
gcloud secrets versions add s360-prod-neo4j-uri       --data-file=- <<< "neo4j+s://…"
gcloud secrets versions add s360-prod-neo4j-password  --data-file=- <<< "…"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/jwt-private.pem
gcloud secrets versions add s360-prod-jwt-private-pem --data-file=/tmp/jwt-private.pem

# 3. hand the CI its variables
scripts/github-setup.sh              # gh variable set on the 8 repos; --check reports drift

# 4. the disposable half, phase by phase
cd ../terraform-core
scripts/bootstrap.sh                 # network + Cloud SQL + identities (targeted)
scripts/bastion.sh up
scripts/db-init.sh                   # schemas, audit table, relay grants (idempotent)
scripts/deploy.sh push all           # the six Java images must exist before the probes run
# fill terraform.tfvars with the pushed image refs, then:
terraform apply                      # services with real images; web+relay from the hello image

# 5. real web + relay images (their pipelines fetch the now-live gateway URL)
gh workflow run deploy.yml -R visionEAE/student360-frontend
gh workflow run deploy.yml -R visionEAE/student360-dwh-relay

# 6. seed and verify
NEO4J_URI="neo4j+s://…" NEO4J_PASSWORD="…" scripts/demo/seed-support-network.sh
GATEWAY_URL="$(cd ../terraform-core && terraform output -raw gateway_url)" \
POSTGRES_PORT=15432 scripts/demo/run.sh          # the whole demonstration thread, against the cloud
# after one scheduler cycle (or: gcloud run jobs execute s360-relay --wait):
bq query 'SELECT count(*) FROM student360_dwh.outbox_events'

scripts/bastion.sh down
```

The last proof of the pipeline itself: push a docs-only commit to a service — the deploy skips
via `paths-ignore`; push a code change — the hash gate builds; revert it — the gate finds the
previous content tag already in the registry and **reuses the digest without building**.

## Demo credentials in production

The seeded accounts are the same as local, but their passwords are **not** `student360`: the
production seed hashes values that live only in Secret Manager (fixed, human-typeable — chosen
for demos, not secrecy). Read them when you need them; never commit them:

```bash
gcloud secrets versions access latest --secret=s360-prod-seed-student-password   # every STUDENT
gcloud secrets versions access latest --secret=s360-prod-seed-staff-password     # ADVISOR + ADMIN
```

The demonstration scripts take them as environment variables:

```bash
DEMO_PASSWORD="$(gcloud secrets versions access latest --secret=s360-prod-seed-student-password)" \
DEMO_STAFF_PASSWORD="$(gcloud secrets versions access latest --secret=s360-prod-seed-staff-password)" \
GATEWAY_URL=… POSTGRES_PORT=15432 scripts/demo/run.sh
```

## Costs (trial account)

Same picture as [gcp-deployment-feasibility.md](gcp-deployment-feasibility.md): Cloud Run, Pub/Sub,
BigQuery, Secret Manager and Scheduler sit inside permanent free tiers at demo scale; AuraDB Free
is free; the only steady cost is Cloud SQL (`db-f1-micro`, ~$10–15/month), and the bastion is a
stopped Always-Free e2-micro. The $300 credit covers many months of continuous operation.
