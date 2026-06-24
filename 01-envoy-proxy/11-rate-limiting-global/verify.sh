#!/usr/bin/env bash
#
# Walk through the global rate-limit setup. Total runtime ~30s.
# We need a bit of warm-up to give the ratelimit service time to
# register with Redis and Envoy.

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"

hr()   { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note() { printf '   \033[2m%s\033[0m\n' "$*"; }

if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.
  make up                       — start the stack
  docker compose ps             — all four containers up?
  docker compose logs ratelimit — RLS config parsed cleanly?
EOF
  exit 1
fi

note "Warming up (give RLS + Redis a moment to settle)..."
curl -sS -o /dev/null "${DATA}/free" || true
sleep 2

# Reset Envoy stats so the post-run counter view is clean.
curl -sX POST "${ADMIN}/reset_counters" >/dev/null

tally() {
  local n=$1 url=$2 ; shift 2
  for _ in $(seq 1 "$n"); do
    curl -sS -o /dev/null -w '%{http_code}\n' "$@" "$url"
  done | sort | uniq -c | sed 's/^/    /'
}

# ----------------------------------------------------------------------- #
hr "1. /free — no rate_limits, no descriptor, no RLS call"
tally 10 "${DATA}/free"

# ----------------------------------------------------------------------- #
hr "2. /global — single shared bucket, 5 req/s"
note "Send 8 rapid requests; expect 5 × 200, 3 × 429."
tally 8 "${DATA}/global"

hr "3. Wait 2s for RLS to roll over the per-second window, then 5 more"
sleep 2
tally 5 "${DATA}/global"

# ----------------------------------------------------------------------- #
hr "4. /per-user — descriptor (user=alice), 2 req/s per unique value"
note "alice's bucket: 4 requests rapid; expect 2 × 200, 2 × 429."
tally 4 "${DATA}/per-user" -H "x-user-id: alice"

hr "5. bob has his OWN bucket — fresh 2 req/s"
note "bob's bucket: 4 requests rapid; expect 2 × 200, 2 × 429."
tally 4 "${DATA}/per-user" -H "x-user-id: bob"

# ----------------------------------------------------------------------- #
hr "6. /per-user without the header — descriptor is dropped, NO limit"
note "Foot-gun: missing header => no descriptor => no RLS call => no limit."
note "Send 10 requests; all 10 should succeed."
tally 10 "${DATA}/per-user"

# ----------------------------------------------------------------------- #
hr "7. Inspect x-ratelimit-* response headers on /global (after refill)"
sleep 2
curl -sS -i "${DATA}/global" 2>/dev/null \
  | head -15 \
  | grep -iE '^(HTTP|x-ratelimit-|x-envoy-ratelimited)' \
  | sed 's/^/    /' || true

# ----------------------------------------------------------------------- #
hr "8. Envoy stats — global counters per HCM and per route"
curl -sS "${ADMIN}/stats?filter=ratelimit" | sort | head -20

hr "9. Ratelimit service stats (via gRPC cluster counters)"
curl -sS "${ADMIN}/stats?filter=cluster\\.ratelimit_cluster\\.(upstream_rq_total|upstream_cx_active|upstream_rq_completed)"

hr "Done."
echo "Useful follow-ups:"
echo "  docker compose logs ratelimit  # what RLS thinks about each request"
echo "  docker exec -it \$(docker compose ps -q redis) redis-cli MONITOR"
echo "  curl -s '${ADMIN}/clusters?cluster=ratelimit_cluster'"
