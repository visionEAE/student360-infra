# Support network — contract (`network-service`, Neo4j)

New capability: a weighted, person-rated graph of who supports a student, plus a purely
relational answer to "which professors currently teach this student" (no rating involved — it is
an academic fact, not an opinion). Two different kinds of data, two different stores, on purpose:

* **`SUPPORTS` edges** are subjective, mutable, rated 1–10 by either side — a real graph problem
  (who is *this* student's strongest support, growing/shrinking over time, potentially many-hop
  in the future). Stored in **Neo4j**, owned by a new service, **`network-service`** (port 8085).
* **"current professors"** is a deterministic join (student → enrolled courses → who teaches
  them) with no rating and no need for graph traversal. Stays relational, added to
  **`core-service`** as a small extension (§3), the existing owner of academic facts.

Both are surfaced together in one composed view so the UI shows "your support network" as one
thing, but the two are independently correct and independently testable.

---

## 1. Domain model (network-service, Neo4j)

### Node: `Person`
```
(:Person {reference, kind, displayName})
```
* `reference` — the cross-service id when one exists (`S-1003`, `A-2001`); a network-generated id
  (`P-<uuid>`) for people who exist only in the support network (a family member, a peer, an
  external counsellor with no login).
* `kind` — `STUDENT | ADVISOR | PROFESSOR | FAMILY | PEER | COUNSELOR | OTHER`.
* `displayName` — shown in the UI; required for `FAMILY`/`PEER`/`OTHER` since they have no other
  profile to pull a name from. For an institutional person it is a **cached label** so the graph can
  be drawn without one directory call per node; opening the person refreshes it (§2.1).
* `email`, `phone`, `summary` — optional contact details **stored only for people the institution
  has no record of** (family, a friend outside the university, an external counsellor, an advisor).
  For a professor or a fellow student they stay null on purpose: core-service's directory is the
  source of truth for those, resolved at read time (§2.1), so a value typed here months ago can
  never shadow the SIS. `summary` describes the *person* and is visible to everyone who may read the
  network; it is not the same thing as an edge's `note`, which is one rater's private remark about
  the relationship.

### Relationship: `SUPPORTS`
```
(:Person)-[:SUPPORTS {weight, relationshipLabel, ratedBy, ratedByReference, note, createdAt, updatedAt}]->(:Person)
```
* Directed **from the person providing support, to the person receiving it** (`(advisor)-[:SUPPORTS]->(student)`).
  A mutual relationship (e.g. two peers who support each other) is two edges, rated independently
  — support is not assumed symmetric.
* `weight` — integer **1–10**, how strong this support is, as judged by whoever rated it.
* `relationshipLabel` — `FAMILY | FRIEND | ADVISOR | MENTOR | COUNSELOR | PROFESSOR | PEER | OTHER`
  (independent of the target's `kind` — a professor can also be rated as a `MENTOR`).
* `ratedBy` / `ratedByReference` — `SELF` (the student rated their own incoming support) or
  `SUPPORT_TEAM` plus the advisor's reference. **Only the student themself or an advisor with an
  active assignment to that student may create or update an edge that points at that student** —
  the same assignment-based authorization `support-service` already enforces, checked here via a
  synchronous call to `support-service`.
* `note` — optional free text (e.g. "always answers late at night"); never logged, same policy as
  a wellbeing entry's note.

A person may edit only edges they themselves authored (`ratedByReference` matches their identity)
except an admin. Two different raters may each keep their own edge toward the same pair (e.g. the
student rates their mother a 9; an advisor separately notes an 8 for the same relationship,
tagged as `SUPPORT_TEAM`) — the UI shows both, it never silently overwrites the other party's
number.

## 2. network-service — CQRS commands and queries

Same discipline as every other service: `application/command` for writes (audited
`STATE_CHANGE`, emits an outbox event even though the record itself lives in Neo4j — the
`common` `EventPublisher` writes to network-service's own Postgres-backed `outbox_event` table
used only for this purpose, since Neo4j is not where outbox rows belong), `application/query`
for reads (audited `DATA_ACCESS`). Handlers depend on a `SupportNetworkRepository` port; the
Neo4j adapter is the only one for stage 1, but the port is what stage 2 could put a managed graph
service behind.

* `POST /api/network/students/{id}/connections` — **UpsertConnectionCommand**
  ```json
  {"person": {"reference": "P-…" , "kind": "FAMILY", "displayName": "Marta Rojas (madre)"},
   "relationshipLabel": "FAMILY", "weight": 9, "note": "optional"}
  ```
  `person.reference` omitted → a new `Person` node is created and its generated id returned.
  `person.reference` matching an existing `Person` → reuses that node (e.g. rating your assigned
  advisor: `{"person":{"reference":"A-2001"}, "relationshipLabel":"ADVISOR","weight":8}`).
  → `201 {"personReference": "…", "weight": 9}`. Self only (student rating their own incoming
  support) — see `PATCH` below for the advisor path.
* `PATCH /api/network/students/{id}/connections/{personReference}` — **UpsertConnectionCommand**
  (same body; updates the caller's own edge, or creates it if absent). Assigned advisors use this
  same endpoint to add or adjust a `SUPPORT_TEAM`-tagged edge for a student they are assigned to.
* `DELETE /api/network/students/{id}/connections/{personReference}` — **RemoveConnectionCommand**
  (removes only the caller's own edge; the other rater's edge, if any, is untouched).
* `GET /api/network/students/{id}/support-network` — **GetSupportNetworkQuery** (self, assigned
  advisor, or admin — same `StudentCaseAccessPolicy` support-service already has, checked here
  identically)
  ```json
  {"studentId":"S-1003","connections":[
    {"person":{"reference":"A-2001","kind":"ADVISOR","displayName":"Carlos Mejía"},
     "edges":[{"weight":8,"relationshipLabel":"ADVISOR","ratedBy":"SELF","updatedAt":"…"}]},
    {"person":{"reference":"P-7f2a…","kind":"FAMILY","displayName":"Marta Rojas (madre)"},
     "edges":[{"weight":9,"relationshipLabel":"FAMILY","ratedBy":"SELF","updatedAt":"…"}]}
  ],"primarySupport":{"person":{...},"edges":[...]},"averageWeight":7.8}
  ```
  `connections` sorted by the caller's own edge weight (their perspective), falling back to the
  other rater's edge when the caller has none yet. `primarySupport` = the single highest-weight
  connection ("quién es tu principal red de apoyo").
* `GET /api/network/advisors/me/students/{id}/support-network` — same query, advisor path,
  identical read model; also returns any `SUPPORT_TEAM`-tagged edges alongside the student's own.

### 2.1 Opening one person — contact details and a short summary

* `GET /api/network/students/{id}/connections/{personReference}` — **GetConnectionDetailQuery**
  (and `GET /api/network/advisors/me/students/{id}/connections/{personReference}`, identical read
  model from the advisor's side)
  ```json
  {"studentId":"S-1003",
   "person":{"reference":"PROF-4","kind":"PROFESSOR","displayName":"Dra. Lucía Fernández"},
   "contact":{"email":"lucia.fernandez@icesi.edu.co","phone":null,
              "summary":"Psicopatología, Psicología Clínica","headline":"Psychology",
              "source":"DIRECTORY"},
   "edges":[{"weight":7,"relationshipLabel":"PROFESSOR","ratedBy":"SELF","updatedAt":"…"}]}
  ```
  **Reachability is decided by the edges, not by the person node**: the person is only returned if
  they actually support *this* student, so knowing a reference is never enough to read somebody's
  contact card out of the graph. A reference that names nobody in this student's network → `404`.

  `contact.source` says where the details came from, and the UI shows it as a badge so nobody
  mistakes a self-entered phone number for an institutional one:

  | `source` | Means | Who |
  |---|---|---|
  | `DIRECTORY` | Resolved from core-service's `GET /api/core/directory/{reference}` at read time | professors (`PROF-*`), fellow students (`S-*`) |
  | `SELF_REPORTED` | Typed in by whoever added the person, stored on the graph node | family, friends, external counsellors, advisors (`A-*`) |
  | `NONE` | Nothing on file — **including when core-service could not be reached** | anyone |

  The directory wins whenever it answered (name and email), but only for what it actually carries:
  it publishes no phone number, so a stored one still shows. Enrichment is additive and degrades
  silently — if core-service is down the card still renders from the graph's own data, marked
  `NONE` rather than failing the whole read. `co.edu.icesi.student360.network.domain.service
  .ConnectionDetailAssembler` holds that precedence rule, pure and unit-tested.

### Picking a `PROFESSOR` or `PEER` — directory-backed, not free text

`person.displayName` is only ever typed by hand for kinds core-service has no record of
(`FAMILY`, `COUNSELOR`, `ADVISOR`, `OTHER`). For `PROFESSOR` and `PEER`, the frontend backs the
picker with core-service's own directory instead: `GET /api/core/directory/search?q=&kind=` (§3
of `docs/api-contract-v2.md`; `kind` is `STUDENT` for a peer, `PROFESSOR` for a professor). The
chosen result's `reference` (`S-1001`, `PROF-4`, …) and `displayName` become `person.reference`
and `person.displayName` on the `UpsertConnectionCommand` above — the resulting `Person` node is
then traceable back to the real SIS record it came from, not an arbitrary string a rater typed.

## 3. core-service extension — "current professors" (relational, no rating)

Flyway (new version only): `core.professor(id, full_name, email, department)`,
`core.course_offering(term, course_code, course_name, professor_id)` seeded for every course code
already used in `course_grade` for the current term (2026-2), one professor per course, plausible
names. No change to `course_grade`; `course_offering` is looked up by `(term, course_code)`.

* `GET /api/core/students/{id}/current-professors` — **GetCurrentProfessorsQueryHandler**
  ```json
  [{"courseCode":"PSI-301","courseName":"Psicopatología","professor":{"id":1,"fullName":"Dra. Lucía Fernández","department":"Psychology"}}]
  ```
  Same `StudentRecordAccessPolicy` as every other core-service read (self / staff / denied).

## 4. Composed view (support-service, no new storage)

`GetStudentCaseQueryHandler` (the existing "vista 360°" / "Ver perfil completo" composition)
gains one more synchronously-fetched, independently-degradable section:
```json
"supportNetwork": {"primarySupport": {...}, "connections": [...]} | null,
"currentProfessors": [...] | null
```
fetched from `network-service` and `core-service` respectively, both added to
`unavailableSources` on failure like every other section already is. `support-service` gets two
new port interfaces (`NetworkServiceClient`, extending the existing `CoreServiceClient` for the
professors call) — no change to its own schema.

## 4.1 Seed — the showcase support networks

The graph has no Flyway equivalent, so unlike every Postgres-backed service — which seeds through
its own migrations — the support network is seeded from infra:

```
make seed-network          # scripts/demo/seed-support-network.sh → infra/seed/network-seed.cypher
```

Idempotent by construction: every write is a `MERGE` on a stable reference, so running it twice
leaves the same graph. That is also why the personal contacts carry readable seed references
(`P-seed-maria-madre`) instead of the `P-<uuid>` the API generates at runtime — a generated id could
not be re-`MERGE`d on a second run.

What the seeded networks are meant to show, read together with the risk profiles core-service seeds:

| Student | Risk | The network says |
|---|---|---|
| `S-1003` María Rojas | HIGH | Deliberately **thin**: her real support is her mother (9/10, the primary); her institutional ties are weak, and the team has started building one — a `SUPPORT_TEAM` edge to the professor of the course she is failing, which she has not rated |
| `S-1001` Ana Torres | LOW | The contrast: broad and balanced — both parents, a friend, a peer, a mentor professor, her advisor |
| `S-1004` Daniel Herrera | MEDIUM | Final year, financially strained: partner, brother, one mentor |
| `S-1005` Camila Torres | MEDIUM | Peer-centred, family far away |
| `S-1008` Santiago Molina | — | Assigned to the **other** advisor (`A-2002`), so both demo logins have a student whose network they may open |

Contact details are seeded only for people core-service has no record of, so the demo exercises all
three `contact.source` values: `SELF_REPORTED` (family, advisors), `DIRECTORY` (professors, peers)
and `NONE` (anyone whose details nobody has filled in).

## 5. Infrastructure

* `infra/docker-compose.yml`: new `neo4j:5-community` container (bolt `7687`, browser `7474`,
  `NEO4J_AUTH=neo4j/${NEO4J_PASSWORD}`, a named volume), started by `make up` alongside Postgres
  — every service needs it running locally the same way they need Postgres, so it is **not**
  profile-gated. `network-service` added to the `services` profile like every other service.
* Gateway: new route `/api/network/**` → `STUDENT, ADVISOR, ADMIN` (same family as
  `/api/support/students/**`), audience `network-service`.
* `network-service`'s own outbox lives in a small local **Postgres** schema (`network`) used
  *only* for `outbox_event` and the append-only audit table — Neo4j holds the graph, Postgres
  holds the two structures every service already has for auditability. Its own DB role, same
  isolation rule as every other schema.

## 6. Frontend

New organism `SupportNetworkCard` (radial or ranked-list view — ranked list for stage 1: sorted
by weight, a crown/star on `primarySupport`) on both the student's own 360° view and the
advisor's student case, plus a small form (person picker or "new person" fields, relationship
label, a 1–10 slider) to add or edit a connection — available to the student for their own
network, and to the advisor for a `SUPPORT_TEAM`-tagged entry on an assigned student.
