#!/usr/bin/env bash
# Loads the showcase support networks into Neo4j (infra/seed/network-seed.cypher).
#
# The graph has no Flyway equivalent, so unlike every Postgres-backed service — which seeds through
# its own migrations — the support network is seeded here, from infra, the same way the wellbeing
# showcase is. The script is idempotent: every write is a MERGE on a stable reference, so running it
# twice leaves the same graph.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
seed="$root/infra/seed/network-seed.cypher"
container="${NEO4J_CONTAINER:-student360-neo4j}"

# NEO4J_URI set in the environment (an AuraDB neo4j+s://… address) targets the cloud instance
# through a disposable cypher-shell container; otherwise the local compose instance as always.
CLOUD_URI="${NEO4J_URI:-}"
[ -f "$root/.env" ] && set -a && . "$root/.env" && set +a
[ -n "$CLOUD_URI" ] && NEO4J_URI="$CLOUD_URI"
: "${NEO4J_PASSWORD:?set NEO4J_PASSWORD in .env (or the environment, for AuraDB)}"

run_cypher() {
  if [ -n "$CLOUD_URI" ]; then
    docker run --rm -i neo4j:5-community cypher-shell -a "$CLOUD_URI" \
      -u "${NEO4J_USER:-neo4j}" -p "$NEO4J_PASSWORD" "$@"
  else
    docker exec -i "$container" cypher-shell -u "${NEO4J_USER:-neo4j}" -p "$NEO4J_PASSWORD" "$@"
  fi
}

if [ -z "$CLOUD_URI" ] && ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
  echo "✗ $container is not running — start it with 'make up' first." >&2
  exit 1
fi

echo "→ seeding support networks into ${CLOUD_URI:-$container}"
run_cypher < "$seed"

people=$(run_cypher --format plain "MATCH (n:Person) RETURN count(n) AS n;" | tail -1)
edges=$(run_cypher --format plain "MATCH ()-[r:SUPPORTS]->() RETURN count(r) AS n;" | tail -1)
echo "✓ support network seeded: $people people, $edges rated connections"
