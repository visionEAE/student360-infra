# Stage 2 feasibility — deploying to GCP on a $300 free-trial account

**Verdict: low-to-moderate complexity, comfortably inside the $300 credit, a few focused days of
work — not a redesign.** The architecture was built for exactly this swap: every cloud-bound
concern (service-to-service auth, secrets, event publishing, tracing) already sits behind a port
in `student360-common` or a service's own `domain/port`, with a local adapter today. Moving to GCP
means writing the cloud adapter behind each port and provisioning the managed services it talks
to — it does not touch business logic, CQRS handlers, or the database schemas.

## 1. Service-by-service mapping

| Component today | GCP target | Why / friction |
|---|---|---|
| `gateway`, `auth-service`, `core-service`, `lms-service`, `support-service`, `network-service` | **Cloud Run**, one service per repository (matches the "independent deployable" rationale already in every repo's README) | Each already has a `Dockerfile`. Cloud Run's free tier (2M requests, 360k GB-seconds, 180k vCPU-seconds **every month, permanently**, not just trial credit) likely covers a demo's entire traffic at $0. |
| `frontend` (static Vite build) | **Firebase Hosting** or a Cloud Storage bucket + Cloud CDN | Cheaper and simpler than another Cloud Run service for a static SPA; Firebase Hosting's free tier (10 GB storage, 360 MB/day transfer, free SSL/custom domain) covers a demo comfortably. |
| Postgres (Docker) | **Cloud SQL for PostgreSQL** | The one real recurring cost (see §3). No schema changes — same `auth`/`core`/`lms`/`support`/`network`/`audit` layout, same per-service database roles. Connect via the Cloud SQL connector library (no VPC needed) or the Auth Proxy sidecar. |
| **Neo4j** (Docker) | **Neo4j AuraDB Free** (Neo4j's own managed cloud, not a GCP product) | The one genuine gap: **GCP has no native managed graph database.** AuraDB Free is free forever, reachable over `neo4j+s://` from anywhere with internet (including Cloud Run, no VPC peering needed), and needs zero GCP billing. This is the pragmatic choice over self-hosting Neo4j on a VM. |
| Locally-signed service token (`LocalServiceTokenProvider`/`Validator`) | **Google-signed ID tokens** (Cloud Run's built-in service identity) | The swap the whole architecture was designed for: each Cloud Run service gets its own service account; caller services fetch an ID token scoped to the callee's URL (metadata server call, a few lines) and the callee validates it against Google's public keys instead of the shared HS256 secret. Bounded, well-documented Cloud Run pattern — implement one new adapter class per port, not a redesign. |
| JWT signing key (PEM file) | **Secret Manager** | `PemSigningKeyProvider`'s only change is reading from Secret Manager instead of a file path — same interface. Secret Manager's free tier (6 active secret versions, 10k access operations/month) covers this alone. |
| `outbox_event` tables | Stays as-is for the demo; **Pub/Sub + a BigQuery subscription** is the next step, not a prerequisite | You can deploy and demo the full system on GCP *before* wiring real publishing — the outbox already holds the exact payload a subscriber would receive. Wiring Pub/Sub is a clean, separable follow-up (a relay job draining the table), not required for a first live deployment. |
| JSON logs on stdout | **Cloud Logging** | Zero code change — Cloud Run captures container stdout as structured logs automatically because the JSON shape is already there. |
| Docker image builds | **Cloud Build** or `gcloud run deploy --source` | Cloud Build's free tier: 120 build-minutes/day. `gcloud run deploy --source .` builds and deploys in one command per service, no separate registry step needed for a demo. |

## 2. What actually has to be written (not just configured)

1. One new adapter per service implementing `ServiceTokenProvider`/`ServiceTokenValidator` against
   Google-signed ID tokens (a Google Auth library dependency + the existing port — see the table
   above). This is the only real *code* change; everything else is configuration/provisioning.
2. `PemSigningKeyProvider`'s Secret Manager variant in `auth-service` (small).
3. Environment/URL wiring: each Cloud Run service's outbound URLs point at the others' `*.run.app`
   addresses (or custom domains) instead of `localhost:808x`; the gateway's JWKS/issuer URI points
   at the deployed `auth-service` URL. All already externalised as environment variables — no code
   change, just different values.
4. A deploy script or a minimal CI workflow (`gcloud run deploy` × 7 services + the frontend
   hosting push) — the repos already have per-service Dockerfiles, so this is glue, not new design.

## 3. Cost, against $300

| Item | Approx. monthly cost if left running 24/7 |
|---|---|
| Cloud Run (7 services, low/demo traffic) | **$0** — inside the permanent free tier |
| Cloud SQL, smallest tier (`db-f1-micro` or shared-core) | **~$10–15/month** |
| Neo4j AuraDB Free | **$0** |
| Secret Manager, Cloud Build, Cloud Logging (light use) | **~$0–1/month**, inside free tiers |
| Firebase Hosting (frontend) | **$0** |
| **Total, left running continuously** | **~$10–15/month** |

At that rate, $300 covers roughly **20 months** of continuous operation — and effectively
indefinitely if Cloud SQL is stopped between demos (Cloud Run itself already scales to zero and
costs nothing while idle). There is no realistic way to exhaust $300 by accident with this
architecture at demo scale; the only cost driver worth watching is leaving Cloud SQL running
unattended for a long time, which is a small, bounded number even then.

## 4. Suggested order of work (if this goes ahead)

1. Provision: a GCP project, Cloud SQL instance (schemas/roles mirroring `infra/init-db`), a Neo4j
   AuraDB Free instance, Secret Manager entries for the JWT key and the Postgres passwords.
2. Write the Google ID token adapter in `student360-common` (or a small new module) behind the
   existing `ServiceTokenProvider`/`ServiceTokenValidator` ports; swap it in per service via Spring
   profile/config — no port signature changes.
3. Deploy `auth-service` first (nothing depends on it being reachable except the gateway's JWKS
   check), then `core-service`, `lms-service`, `support-service`, `network-service`, then `gateway`
   last (it needs every other URL), then the frontend.
4. Re-run the existing demonstration thread (`scripts/demo/run.sh`) against the deployed URLs
   instead of `localhost` — it is already parameterised by `GATEWAY_URL`.

None of this requires touching CQRS handlers, the Neo4j graph model, the database schemas, or any
business rule — which is the point of having built stage 1 behind these interfaces from the start.
