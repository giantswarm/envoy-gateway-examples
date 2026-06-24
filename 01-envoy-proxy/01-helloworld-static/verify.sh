#!/usr/bin/env bash
#
# Drives the example: hits the listener through Envoy and pokes a couple of
# admin endpoints so you can confirm what's running.
#
# Requires: curl, jq.

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"

hr() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.

  1. Did you start the stack?       make up
  2. Are containers running?        docker compose ps
  3. Did Envoy crash on startup?    docker compose logs envoy | tail -30
  4. Port already in use?           lsof -i :10000 -i :9901
EOF
  exit 1
fi

hr "GET ${DATA}/"
curl -sS "${DATA}/" | jq .

hr "GET ${DATA}/headers (note x-envoy-* headers Envoy added)"
curl -sS "${DATA}/headers" | jq .

hr "Three more requests (steady response)"
for i in 1 2 3; do
  curl -sS "${DATA}/" | jq -c .
done

hr "Admin ${ADMIN}/ready"
curl -sS "${ADMIN}/ready" || true

hr "Admin ${ADMIN}/clusters?cluster=helloworld_cluster (first 15 lines)"
curl -sS "${ADMIN}/clusters?cluster=helloworld_cluster" | head -15 || true

hr "Done. Try also:"
echo "  curl -s ${ADMIN}/config_dump | jq . | less"
echo "  curl -s ${ADMIN}/stats | grep helloworld_cluster"
