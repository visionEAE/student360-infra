// Showcase support networks (network-service, Neo4j) — see docs/network-contract.md.
//
// Idempotent on purpose: every write is a MERGE on a stable reference, so running it twice leaves
// the same graph rather than a second copy of every person. That is why the personal contacts use
// readable seed references (P-seed-*) instead of the P-<uuid> the API generates at runtime — a
// generated id could not be re-MERGEd on a second run.
//
// What each network is meant to show, read together with the risk profiles core-service seeds:
//   S-1003 María Rojas (HIGH risk)  — a deliberately THIN network. Her real support is her mother;
//                                     her institutional ties are weak, and the support team has
//                                     started building one (a SUPPORT_TEAM edge she has not rated).
//   S-1001 Ana Torres  (LOW risk)   — the contrast: a broad, balanced network, family + peers +
//                                     a mentor professor + her advisor.
//   S-1004 Daniel Herrera (MEDIUM)  — final-year, financially strained: partner and one mentor.
//   S-1005 Camila Torres  (MEDIUM)  — peer-centred, family far away.
//   S-1008 Santiago Molina          — assigned to the OTHER advisor (A-2002), so both demo logins
//                                     have a student with a network to open.
//
// Contact details are stored ONLY for people core-service has no record of (family, friends,
// advisors). Professors and fellow students deliberately carry none: the read side resolves those
// from core-service's directory, so the card shows source=DIRECTORY for them, SELF_REPORTED for the
// personal ones, and the demo exercises both paths.

// ---------------------------------------------------------------- students (graph-side anchors)
// displayName is stored here as a cached label, exactly as the API stores it when a peer is added
// through the picker: the graph needs something to draw on the node without a directory call per
// node. It is only a cache — opening the person refreshes the name from core-service's directory.
UNWIND [
  {reference: 'S-1001', displayName: 'Ana Torres'},
  {reference: 'S-1003', displayName: 'María Rojas'},
  {reference: 'S-1004', displayName: 'Daniel Herrera'},
  {reference: 'S-1005', displayName: 'Camila Torres'},
  {reference: 'S-1007', displayName: 'Juan Pablo Gómez'},
  {reference: 'S-1008', displayName: 'Santiago Molina'}
] AS student
MERGE (s:Person {reference: student.reference})
  SET s.kind = 'STUDENT', s.displayName = student.displayName;

// ------------------------------------------------------------------------------- professors
// No contact stored: core-service's directory is the source of truth for these.
UNWIND [
  {reference: 'PROF-1',  displayName: 'Dr. Andrés Salazar'},
  {reference: 'PROF-4',  displayName: 'Dra. Lucía Fernández'},
  {reference: 'PROF-6',  displayName: 'Dra. Paula Escobar'},
  {reference: 'PROF-7',  displayName: 'Dr. Óscar Medina'},
  {reference: 'PROF-8',  displayName: 'Dra. Camila Restrepo'},
  {reference: 'PROF-15', displayName: 'Dra. Diana Herrera'}
] AS professor
MERGE (p:Person {reference: professor.reference})
  SET p.kind = 'PROFESSOR', p.displayName = professor.displayName;

// --------------------------------------------------------------------------------- advisors
// core-service has no advisor directory, so their contact details live here.
UNWIND [
  {reference: 'A-2001', displayName: 'Carlos Mejía', email: 'carlos.mejia@icesi.edu.co',
   phone: '+57 602 555 0101', summary: 'Acompañante académico · Facultad de Ingeniería y Ciencias Sociales'},
  {reference: 'A-2002', displayName: 'Diana Pérez', email: 'diana.perez@icesi.edu.co',
   phone: '+57 602 555 0102', summary: 'Acompañante académica · Facultad de Derecho y Diseño'}
] AS advisor
MERGE (a:Person {reference: advisor.reference})
  SET a.kind = 'ADVISOR', a.displayName = advisor.displayName,
      a.email = advisor.email, a.phone = advisor.phone, a.summary = advisor.summary;

// ------------------------------------------------------- personal contacts (family / friends)
UNWIND [
  {reference: 'P-seed-maria-madre', kind: 'FAMILY', displayName: 'Marta Rojas (madre)',
   email: 'marta.rojas@example.com', phone: '+57 315 442 8890',
   summary: 'Mi mamá. Vive en Cali, hablamos casi todos los días.'},
  {reference: 'P-seed-ana-madre', kind: 'FAMILY', displayName: 'Patricia Rendón (mamá)',
   email: 'patricia.rendon@example.com', phone: '+57 310 220 4471',
   summary: 'Mi mamá. Es con quien primero hablo cuando algo me preocupa.'},
  {reference: 'P-seed-ana-padre', kind: 'FAMILY', displayName: 'Jorge Torres (papá)',
   email: 'jorge.torres@example.com', phone: '+57 300 118 9032',
   summary: 'Mi papá. Me ayuda sobre todo con los temas de matrícula.'},
  {reference: 'P-seed-ana-amiga', kind: 'PEER', displayName: 'Laura Jiménez',
   email: 'laura.jimenez@example.com', phone: '+57 318 776 5540',
   summary: 'Mi mejor amiga del colegio. No estudia en Icesi pero nos vemos cada semana.'},
  {reference: 'P-seed-daniel-pareja', kind: 'FAMILY', displayName: 'Andrea Lozano (pareja)',
   email: 'andrea.lozano@example.com', phone: '+57 312 908 3317',
   summary: 'Mi pareja. Vivimos juntos, es mi apoyo diario en la rotación.'},
  {reference: 'P-seed-daniel-hermano', kind: 'FAMILY', displayName: 'Felipe Herrera (hermano)',
   email: 'felipe.herrera@example.com', phone: '+57 301 559 7724',
   summary: 'Mi hermano mayor, también estudió Medicina.'},
  {reference: 'P-seed-camila-tia', kind: 'FAMILY', displayName: 'Gloria Torres (tía)',
   email: 'gloria.torres@example.com', phone: '+57 316 330 1180',
   summary: 'Mi tía. Vivo con ella en Cali mientras mi familia está en Pasto.'},
  {reference: 'P-seed-santiago-madre', kind: 'FAMILY', displayName: 'Rosa Molina (mamá)',
   email: 'rosa.molina@example.com', phone: '+57 314 667 2205',
   summary: 'Mi mamá. Trabaja en Popayán, nos vemos un fin de semana al mes.'}
] AS person
MERGE (p:Person {reference: person.reference})
  SET p.kind = person.kind, p.displayName = person.displayName,
      p.email = person.email, p.phone = person.phone, p.summary = person.summary;

// --------------------------------------------------------------------------------- the edges
// (supporter)-[:SUPPORTS]->(student), one row per rater, exactly as the API writes them.
UNWIND [
  // S-1003 María Rojas — thin network, one strong tie.
  {from: 'P-seed-maria-madre', to: 'S-1003', weight: 9, label: 'FAMILY',    by: 'SELF',         byRef: 'S-1003', note: 'Siempre está, aunque no le he contado lo de la deuda.'},
  {from: 'PROF-4',             to: 'S-1003', weight: 7, label: 'PROFESSOR', by: 'SELF',         byRef: 'S-1003', note: 'Es la única profe con la que me siento cómoda preguntando.'},
  {from: 'A-2001',             to: 'S-1003', weight: 5, label: 'ADVISOR',   by: 'SELF',         byRef: 'S-1003', note: null},
  {from: 'A-2001',             to: 'S-1003', weight: 6, label: 'ADVISOR',   by: 'SUPPORT_TEAM', byRef: 'A-2001', note: 'Contacto quincenal desde la alerta de agosto.'},
  {from: 'PROF-7',             to: 'S-1003', weight: 4, label: 'PROFESSOR', by: 'SUPPORT_TEAM', byRef: 'A-2001', note: 'Vínculo por construir: es quien dicta Estadística II, el curso en riesgo.'},

  // S-1001 Ana Torres — broad, balanced network.
  {from: 'P-seed-ana-madre', to: 'S-1001', weight: 9, label: 'FAMILY',    by: 'SELF', byRef: 'S-1001', note: null},
  {from: 'P-seed-ana-padre', to: 'S-1001', weight: 8, label: 'FAMILY',    by: 'SELF', byRef: 'S-1001', note: null},
  {from: 'P-seed-ana-amiga', to: 'S-1001', weight: 8, label: 'FRIEND',    by: 'SELF', byRef: 'S-1001', note: null},
  {from: 'S-1007',           to: 'S-1001', weight: 7, label: 'PEER',      by: 'SELF', byRef: 'S-1001', note: 'Estudiamos juntos casi todos los parciales.'},
  {from: 'PROF-1',           to: 'S-1001', weight: 8, label: 'MENTOR',    by: 'SELF', byRef: 'S-1001', note: 'Me está asesorando el proyecto de grado.'},
  {from: 'A-2001',           to: 'S-1001', weight: 6, label: 'ADVISOR',   by: 'SELF', byRef: 'S-1001', note: null},

  // S-1004 Daniel Herrera — final year, financially strained.
  {from: 'P-seed-daniel-pareja',  to: 'S-1004', weight: 9, label: 'FAMILY',    by: 'SELF',         byRef: 'S-1004', note: null},
  {from: 'P-seed-daniel-hermano', to: 'S-1004', weight: 6, label: 'FAMILY',    by: 'SELF',         byRef: 'S-1004', note: null},
  {from: 'PROF-8',                to: 'S-1004', weight: 7, label: 'MENTOR',    by: 'SELF',         byRef: 'S-1004', note: 'Jefa de rotación, me ha ayudado a reorganizar turnos.'},
  {from: 'A-2001',                to: 'S-1004', weight: 5, label: 'ADVISOR',   by: 'SELF',         byRef: 'S-1004', note: null},
  {from: 'A-2001',                to: 'S-1004', weight: 6, label: 'ADVISOR',   by: 'SUPPORT_TEAM', byRef: 'A-2001', note: 'Remitido a Bienestar Financiero en agosto.'},

  // S-1005 Camila Torres — peer-centred, family far away.
  {from: 'S-1003',            to: 'S-1005', weight: 8, label: 'PEER',      by: 'SELF', byRef: 'S-1005', note: 'Vamos juntas a casi todas las clases de la carrera.'},
  {from: 'PROF-6',            to: 'S-1005', weight: 7, label: 'PROFESSOR', by: 'SELF', byRef: 'S-1005', note: null},
  {from: 'P-seed-camila-tia', to: 'S-1005', weight: 7, label: 'FAMILY',    by: 'SELF', byRef: 'S-1005', note: null},
  {from: 'A-2001',            to: 'S-1005', weight: 4, label: 'ADVISOR',   by: 'SELF', byRef: 'S-1005', note: null},

  // S-1008 Santiago Molina — the other advisor's student.
  {from: 'P-seed-santiago-madre', to: 'S-1008', weight: 8, label: 'FAMILY',    by: 'SELF',         byRef: 'S-1008', note: null},
  {from: 'PROF-15',               to: 'S-1008', weight: 6, label: 'PROFESSOR', by: 'SELF',         byRef: 'S-1008', note: null},
  {from: 'A-2002',                to: 'S-1008', weight: 6, label: 'ADVISOR',   by: 'SELF',         byRef: 'S-1008', note: null},
  {from: 'A-2002',                to: 'S-1008', weight: 7, label: 'ADVISOR',   by: 'SUPPORT_TEAM', byRef: 'A-2002', note: 'Seguimiento mensual, va bien.'}
] AS e
MATCH (supporter:Person {reference: e.from})
MATCH (student:Person {reference: e.to})
MERGE (supporter)-[edge:SUPPORTS {ratedByReference: e.byRef}]->(student)
  ON CREATE SET edge.createdAt = '2026-08-01T09:00:00Z'
SET edge.weight = e.weight,
    edge.relationshipLabel = e.label,
    edge.ratedBy = e.by,
    edge.note = e.note,
    edge.updatedAt = '2026-08-20T09:00:00Z';
