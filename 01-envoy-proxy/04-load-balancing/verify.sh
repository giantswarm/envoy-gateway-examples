#!/usr/bin/env bash
#
# Demonstrates round-robin distribution and ring-hash stickiness.
# Least-request is harder to show without a concurrent load generator —
# the README has the recipe (hey/vegeta).

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"

hr()  { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note(){ printf '   \033[2m%s\033[0m\n' "$*"; }

if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.
  make up                       — start the stack
  docker compose ps             — containers running?
  docker compose logs envoy     — config rejected?
  lsof -i :10000 -i :9901       — port already in use?
EOF
  exit 1
fi

# ----------------------------------------------------------------------- #
hr "1. ROUND_ROBIN  (/rr)"
note "30 requests; expect ~10 per backend"
for i in $(seq 1 30); do
  curl -sS "${DATA}/rr" | jq -r .from_
done | sort | uniq -c

# ----------------------------------------------------------------------- #
hr "2. RING_HASH  (/rh) — stickiness on x-user-id"
note "Each user hashes to one endpoint; mapping is stable across runs."
for run in 1 2 3; do
  echo "  --- run $run ---"
  for user in alice bob carol dave eve frank; do
    backend=$(curl -sS -H "x-user-id: ${user}" "${DATA}/rh" | jq -r .from_)
    printf "  %-6s -> %s\n" "${user}" "${backend}"
  done
done

# ----------------------------------------------------------------------- #
hr "3. RING_HASH (/rh) — no header  ->  random pick per request"
note "Without x-user-id the hash_policy has nothing; Envoy picks randomly."
for i in $(seq 1 10); do
  curl -sS "${DATA}/rh" | jq -r .from_
done | sort | uniq -c

# ----------------------------------------------------------------------- #
hr "4. LEAST_REQUEST  (/lr) — sequential, no contention"
note "Sequential traffic looks ~uniform; the policy shines under concurrent load."
note "See README exercise for a hey/vegeta demo with contention."
for i in $(seq 1 30); do
  curl -sS "${DATA}/lr" | jq -r .from_
done | sort | uniq -c

# ----------------------------------------------------------------------- #
hr "5. Per-cluster /stats — pick a counter"
note "upstream_rq_total per cluster — should reflect the runs above."
for c in cluster_rr cluster_lr cluster_rh; do
  count=$(curl -sS "${ADMIN}/stats?filter=cluster.${c}.upstream_rq_total$" \
            | awk -F': ' '{print $2}' || true)
  printf "  %-12s upstream_rq_total = %s\n" "${c}" "${count:-?}"
done

hr "Done."
echo "Per-endpoint counters: curl -s ${ADMIN}/clusters?cluster=cluster_rr | head"
