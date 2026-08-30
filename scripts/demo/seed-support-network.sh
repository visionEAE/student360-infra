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

[ -f "$root/.env" ] && set -a && . "$root/.env" && set +a
: "${NEO4J_PASSWORD:?set NEO4J_PASSWORD in .env}"

if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
  echo "✗ $container is not running — start it with 'make up' first." >&2
  exit 1
fi

echo "→ seeding support networks into $container"
docker exec -i "$container" cypher-shell -u "${NEO4J_USER:-neo4j}" -p "$NEO4J_PASSWORD" < "$seed"

people=$(docker exec "$container" cypher-shell -u "${NEO4J_USER:-neo4j}" -p "$NEO4J_PASSWORD" \
  --format plain "MATCH (n:Person) RETURN count(n) AS n;" | tail -1)
edges=$(docker exec "$container" cypher-shell -u "${NEO4J_USER:-neo4j}" -p "$NEO4J_PASSWORD" \
  --format plain "MATCH ()-[r:SUPPORTS]->() RETURN count(r) AS n;" | tail -1)
echo "✓ support network seeded: $people people, $edges rated connections"
