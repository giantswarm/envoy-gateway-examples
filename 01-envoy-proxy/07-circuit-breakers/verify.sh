#!/usr/bin/env bash
#
# Burst the cluster with 15 concurrent slow requests and observe the
# circuit breakers trip. Takes about 7 seconds end-to-end (one batch of
# 3 hits backend for ~3s, then the 2 pending take ~3s more).

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"
N=15
SECONDS=3

hr()   { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note() { printf '   \033[2m%s\033[0m\n' "$*"; }

if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.
  make up                       — start the stack
  docker compose ps             — containers running?
  docker compose logs envoy     — config rejected?
EOF
  exit 1
fi

# ----------------------------------------------------------------------- #
hr "1. Show the configured thresholds"
curl -sS "${ADMIN}/config_dump" \
  | jq '.configs[]
        | select(."@type"|endswith("ClustersConfigDump"))
        | .static_clusters[].cluster
        | {name, circuit_breakers}'

# ----------------------------------------------------------------------- #
hr "2. Baseline single request"
note "Should take ~${SECONDS}s and return 200."
code_and_time=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}s' \
                  "${DATA}/?seconds=${SECONDS}")
echo "  HTTP ${code_and_time}"

# ----------------------------------------------------------------------- #
# Reset counters so the burst's numbers are clean and easy to read.
curl -sX POST "${ADMIN}/reset_counters" >/dev/null

hr "3. ${N} concurrent requests; circuit breakers should reject most"
note "Expect ~5 success (3 in-flight + 2 pending) and ~10 503 / UO."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for i in $(seq 1 "$N"); do
  curl -sS -o /dev/null -w '%{http_code}\n' \
       "${DATA}/?seconds=${SECONDS}" > "${tmp}/${i}" &
done
wait
echo
echo "  Status code tally:"
cat "${tmp}"/* | sort | uniq -c | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "4. Overflow counters"
note "Increments when a threshold rejected a request."
curl -sS "${ADMIN}/stats?filter=cluster\\.cluster_slow\\.upstream_(cx|rq)(_pending)?_overflow" \
  | sort

# ----------------------------------------------------------------------- #
hr "5. Remaining-capacity gauges (track_remaining)"
note "remaining_* shows current headroom; *_open is 1 when a threshold is breached."
curl -sS "${ADMIN}/stats?filter=cluster\\.cluster_slow\\.circuit_breakers" \
  | sort

# ----------------------------------------------------------------------- #
hr "6. Spot-check one 503 to confirm RESPONSE_FLAGS + x-envoy-overloaded"
note "Hit one more during a fresh burst so we capture an overflow response."
( for i in 1 2 3 4 5; do curl -sS -o /dev/null "${DATA}/?seconds=${SECONDS}" & done ) &
sleep 0.2
curl -sS -i -o /tmp/cb.headers -w '\n  HTTP %{http_code} in %{time_total}s\n' \
     "${DATA}/?seconds=${SECONDS}" | tail -2
echo "  Headers (filtered):"
grep -iE '^(x-envoy-overloaded|server|content-type|content-length):' /tmp/cb.headers || true
wait 2>/dev/null || true

hr "Done."
echo "Replay the burst at any time with:    make burst [N=25] [SECONDS=2]"
echo "Watch counters live:                  make watch"
