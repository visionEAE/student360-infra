# API contract v2 — driven by `pen_design/vision360.pen`

Every screen of the design maps to these endpoints. All go through the gateway (`/api/**`), all
errors are RFC 7807 `{title, status, detail, requestId}`. Dates are ISO-8601 UTC; money is a
decimal in COP. Identifiers stay the cross-service keys (`S-1003`, `A-2001`).

Architecture rules that apply everywhere:
* **CQRS**: every use case is either a `…Command` handled by a `…CommandHandler` (writes, emits
  events, audited as `STATE_CHANGE`) or a `…Query` handled by a `…QueryHandler` (reads, returns a
  read model record, audited as `DATA_ACCESS`). Controllers only translate HTTP ⇄ command/query.
  Packages: `application/command/*`, `application/query/*`, read models in `application/query/model`.
* **Interfaces**: handlers depend on ports in `domain/port` (repositories, source clients,
  pseudonymizer, clock…). Adapters live in `infrastructure/*`. No handler imports JPA, Feign or HTTP.
* Fine-grained authorization inside the handler (`StudentRecordAccessPolicy`, assignment policy),
  authorization before existence, denied outcomes audited.

---

## core-service (`/api/core`) — SIS + ERP, read-only queries

### `GET /students/{id}` → `StudentProfile`
```json
{"id":"S-1003","code":"2025145032","fullName":"María Rojas","firstName":"María","lastName":"Rojas",
 "email":"…","program":{"code":"PSI","name":"Psychology","faculty":"Social Sciences","totalSemesters":10},
 "currentSemester":7,"admissionTerm":"2025-1","status":"ACTIVE","enrollmentStatus":"ACTIVE"}
```
### `GET /students/{id}/academic-status` → `AcademicStatus`
```json
{"studentId":"S-1003","currentTerm":"2026-2","currentSemester":7,"totalSemesters":10,
 "academicStanding":"AT_RISK","enrollmentStatus":"ACTIVE","cumulativeGpa":2.95,"creditsEnrolled":12,
 "gpaHistory":[{"semester":5,"term":"2025-1","termGpa":3.10},{"semester":6,"term":"2026-1","termGpa":2.70}],
 "currentCourses":[{"code":"PSI-301","name":"Psicopatología","credits":3,"currentGrade":2.8}],
 "sourceUpdatedAt":"2026-08-30T10:00:00Z"}
```
`gpaHistory` = every past term with a grade, oldest first (the "Evolución del promedio" chart).
`currentCourses` = official gradebook of the current term (`currentGrade` may be null).

### `GET /students/{id}/financial-status` → `FinancialStatus`
```json
{"studentId":"S-1003","tuitionAmount":8500000.00,"paidAmount":7260000.00,"outstandingBalance":1240000.00,
 "overdueBalance":1240000.00,"daysOverdue":62,"overdue":true,"dueDate":"2026-08-15",
 "paymentPlan":null,"scholarship":"20% por mérito académico","financialHold":true,
 "payments":[{"date":"2026-02-20","description":"Derechos de matrícula","amount":600000.00,"status":"PAID"}],
 "updatedAt":"…"}
```
`payments` sorted by date ascending; `status` ∈ `PAID | PENDING | OVERDUE`. `paymentPlan` is a
short text or null ("Ninguno activo" is rendered by the UI).

### `GET /students/summaries?ids=S-1001,S-1003` → `[StudentSummary]` (staff only)
```json
[{"id":"S-1003","code":"2025145032","fullName":"María Rojas","program":{"code":"PSI","name":"Psychology"},
  "currentSemester":7,"academicStanding":"AT_RISK","overdue":true,"daysOverdue":62,"outstandingBalance":1240000.00,
  "updatedAt":"…"}]
```
Audit action `READ_STUDENT_SUMMARIES` (subject `STUDENT_BATCH`, subject id = the ids). Unknown ids
are skipped. Max 100 ids.

Schema additions (Flyway `V3__…`): `program.total_semesters`, `student.code` (unique),
`student.current_semester`, `enrollment.semester_number`, new `core.course_grade` (`student_id`,
`term`, `course_code`, `course_name`, `credits`, `current_grade`), new `core.tuition_payment`
(`student_id`, `due_date`, `paid_at`, `description`, `amount`, `status`), `financial_status`
gains `tuition_amount`, `paid_amount`, `due_date`, `payment_plan` (text), `scholarship` (text).
Seed (`V4__…`): S-1001/S-1002/S-1003 completed with these fields **plus three new students** with
no login: `S-1004` Daniel Herrera (Medicine, at risk academic + financial), `S-1005` Camila Torres
(Psychology, academic at risk only), `S-1006` Valentina Ospina (Design, everything on track).
S-1003 keeps the design's numbers where sensible: tuition 8 500 000, paid 7 260 000, pending
1 240 000 overdue since 2026-08-15, scholarship 20 %, GPA history 3.6/3.5/3.2/3.5/3.4 for
semesters 3–7, 5 current courses (one with 2.8).

---

## lms-service (`/api/lms`) — learning platform, read-only queries

### `GET /students/{id}/signals` → `EngagementSignals` (unchanged fields + additions)
```json
{"studentId":"S-1003","computedAt":"…","daysSinceLastAccess":18,"lastAccessAt":"…",
 "onTimeSubmissionRate":0.62,"coursesWithoutActivity":2,"activeCourses":5,
 "accessCount30d":6,"lateSubmissions":3,"missingSubmissions":4}
```
### `GET /students/{id}/activity?days=30` → `EngagementActivity`
```json
{"studentId":"S-1003","windowDays":30,"accessCount":6,"lastAccessAt":"…",
 "submissions":{"onTime":8,"late":3,"missing":4},
 "courses":[{"courseCode":"PSI-301","courseName":"…","lastAccessAt":"…","daysSinceLastAccess":3,
            "onTime":4,"late":1,"missing":0,"participation":"ACTIVE"}]}
```
`participation` ∈ `ACTIVE | MODERATE | LOW | INACTIVE` (computed by the LMS: inactive = no access in
the window; low = >14 days or missing ≥ 2; moderate = >7 days or any late; active otherwise).

### `GET /students/signals?ids=…` → `[EngagementSignals]` (staff only, audit `READ_ENGAGEMENT_SIGNALS_BATCH`)

Seed (`V3__…`): enrollments/activity for `S-1004`, `S-1005`, `S-1006` with patterns matching
their core profiles; S-1003 with 5 courses: 3 days / 18 days / 5 days / 20 days / 12 days since
last access, so the per-course table looks like the design.

---

## support-service (`/api/support`) — commands and queries

### Wellbeing entry v2 (student "Mi espacio seguro")
An entry has three **dimensions** — `ECONOMIC`, `ACADEMIC`, `EMOTIONAL` — each with a `mood`
(`DIFFICULT`=1, `FAIR`=2, `GOOD`=3, `VERY_GOOD`=4), a list of `needs` codes and an optional `note`.
The entry `level` (1–4) is the minimum mood; the rule treats `level ≤ 2` as low. Status
`DRAFT | SENT`; drafts never run the rule and are invisible to advisors.

Needs codes: ECONOMIC `SCHOLARSHIP_INFO, PAYMENT_PLAN, TALK_FINANCIAL_WELLBEING, NOTHING`;
ACADEMIC `TUTORING, ADJUST_WORKLOAD, TALK_TO_PROFESSOR, NOTHING`; EMOTIONAL `TALK_TO_SOMEONE,
PSYCHOLOGICAL_SUPPORT, JUST_SHARING, NOTHING`.

* `POST /students/{id}/wellbeing-entries` — **SubmitWellbeingEntryCommand** / **SaveWellbeingDraftCommand**
  ```json
  {"status":"SENT","dimensions":[{"dimension":"ECONOMIC","mood":"DIFFICULT","needs":["PAYMENT_PLAN"],"note":"…"},
   {"dimension":"ACADEMIC","mood":"FAIR","needs":["TUTORING"]},{"dimension":"EMOTIONAL","mood":"DIFFICULT","needs":["TALK_TO_SOMEONE","PSYCHOLOGICAL_SUPPORT"]}]}
  ```
  → `201 {"entryId":"…","status":"SENT","level":1,"alertGenerated":true,"alertId":"…"}`.
  All three dimensions are required when `SENT`; any subset when `DRAFT`.
* `PUT /students/{id}/wellbeing-entries/{entryId}` — same body; updates a draft, or sends it
  (`status: SENT` runs the rule). `409` if the entry is already sent.
* `GET /students/{id}/wellbeing-entries/draft` → the latest draft or `204`.
* `GET /students/{id}/wellbeing-summary` → **WellbeingSummaryQuery** (self, assigned advisor, admin)
  ```json
  {"studentId":"S-1003","currentLevel":1,"currentLevelLabel":"LOW","entriesThisMonth":4,"trend":"DOWN",
   "weekly":[{"weekStart":"2026-07-20","label":"S1","level":3}, …6 weeks…],
   "recent":[{"entryId":"…","recordedAt":"…","level":1,"summaryNote":"…","dimensions":[{"dimension":"ECONOMIC","mood":"DIFFICULT","needs":["PAYMENT_PLAN"],"note":"…"}]}]}
  ```
  `currentLevelLabel` ∈ `LOW (1) | MEDIUM (2) | GOOD (3–4)`; `trend` ∈ `UP | DOWN | STABLE` comparing
  the last two sent entries; `recent` = last 10 sent entries, newest first; `weekly` = last 6 ISO
  weeks (level = min level of the week, null when no entry).

### Advisor screens
* `GET /advisors/me/students` → **AdvisorStudentsOverviewQuery**
  ```json
  {"advisorReference":"A-2001","students":[{"studentId":"S-1003","code":"…","fullName":"…","initials":"MR",
    "program":"Psychology","currentSemester":7,"academicStatus":"WATCH","financialStatus":"AT_RISK",
    "emotionalStatus":"AT_RISK","overallRisk":"HIGH","openAlertId":"…","lastUpdatedAt":"…"}],
   "unavailableSources":[]}
  ```
  Status scale `ON_TRACK | WATCH | AT_RISK | UNKNOWN` (`UNKNOWN` when the source failed or no data):
  academic from `academicStanding` (GOOD→ON_TRACK, PROBATION→WATCH, AT_RISK→AT_RISK); financial
  (overdue→AT_RISK, outstanding balance without overdue→WATCH, zero→ON_TRACK); emotional from the
  latest sent entry level (1→AT_RISK, 2→WATCH, ≥3→ON_TRACK, none→UNKNOWN). `overallRisk`
  `LOW | MEDIUM | HIGH`: HIGH if an open/acknowledged HIGH alert or all three AT_RISK; MEDIUM if an
  open MEDIUM alert, any AT_RISK or ≥2 WATCH; else LOW. Sorted highest risk first.
* `GET /advisors/me/students/{id}` → **StudentCaseQuery** (assignment required; basis `ASSIGNMENT`)
  ```json
  {"student":{…StudentProfile…},"assignment":{"advisorReference":"A-2001","validFrom":"2026-01-15"},
   "academic":{…AcademicStatus…}|null,"financial":{…FinancialStatus…}|null,"engagement":{…EngagementSignals…}|null,
   "activeAlert":{"id":"…","severity":"HIGH","status":"OPEN","source":"CONVERGENT_RISK_RULE_V1","generatedAt":"…",
      "triggeringSignals":{…},"interventionPlan":{"id":"…","type":"INTEGRAL_SUPPORT","description":"…","status":"PROPOSED","createdBy":null},
      "reports":[…]}|null,
   "wellbeing":{…WellbeingSummary…}|null,"unavailableSources":["lms-service"]}
  ```
  Sections that fail are null and listed in `unavailableSources` (partial degradation).
* `GET /advisors/me/alerts` / `GET /advisors/me/alerts/{id}` — unchanged (AlertInboxQuery, AlertDetailQuery).
* `POST /advisors/me/alerts/{id}/reports` `{content}` — **AddSupportReportCommand** (unchanged).
* `POST /advisors/me/students/{id}/intervention-plans` `{type, description}` — **CreateInterventionPlanCommand**
  ("Nueva intervención"; `alertId` optional in body) → `201 {planId}`. Plan gets `student_reference`, `created_by`.
* `PATCH /advisors/me/intervention-plans/{planId}` `{status: ACTIVE|COMPLETED}` — **UpdateInterventionPlanStatusCommand**
  ("Aceptar ruta" = ACTIVE). Emits `INTERVENTION_PLAN_UPDATED`.
* `GET /advisors/me/intervention-plans` → **InterventionPlansQuery**: `[{id, studentId, studentName?, type, description, status, alertId, createdAt}]` for the advisor's assigned students (page "Intervenciones").
* `GET /advisors/me/reports` → **SupportReportsQuery**: `[{id, alertId, studentId, content, createdAt}]` (page "Reportes").

Schema (`V3__…`): `wellbeing_entry.status`, `wellbeing_entry_dimension` (entry_id, dimension, mood, needs TEXT[], note),
`intervention_plan.alert_id` nullable + `student_reference`, `created_by`, `created_at`, `updated_at`.

---

## auth-service — unchanged
`/api/auth/me` already returns `fullName`, `roles`, `externalReference`; the UI derives initials
and the role label ("Acompañante académica" / "Estudiante").

## gateway — unchanged
`/api/core/**`, `/api/lms/**` allow STUDENT/ADVISOR/ADMIN (batch endpoints reject students downstream);
`/api/support/students/**` STUDENT/ADVISOR; `/api/support/advisors/**` ADVISOR/ADMIN.
