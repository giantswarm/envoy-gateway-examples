#!/usr/bin/env bash
#
# Walk through the local rate limit filter:
#  - /free        no limit
#  - /limited     5 tokens, 1/s, default 429
#  - /limited-custom  custom 503 with retry-after
#
# Total runtime ~15s (one ~6s wait to refill between scenarios).

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"

hr()   { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note() { printf '   \033[2m%s\033[0m\n' "$*"; }

if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.
  make up                       — start the stack
  docker compose logs envoy     — config rejected?
EOF
  exit 1
fi

# Make sure both buckets are full before the demo (warm bucket from any
# prior test run).
note "Waiting 6s for any prior buckets to refill before we start..."
sleep 6

# Reset counters so the stat output at the end is meaningful.
curl -sX POST "${ADMIN}/reset_counters" >/dev/null

tally() {
  local n=$1 url=$2
  for _ in $(seq 1 "$n"); do
    curl -sS -o /dev/null -w '%{http_code}\n' "$url"
  done | sort | uniq -c | sed 's/^/    /'
}

# ----------------------------------------------------------------------- #
hr "1. /free — no rate limit; 10 rapid requests"
note "Expect 10 × 200."
tally 10 "${DATA}/free"

# ----------------------------------------------------------------------- #
hr "2. /limited — 5 tokens, 1/s refill; 8 rapid requests"
note "Expect 5 × 200, 3 × 429 (the default over-limit status)."
tally 8 "${DATA}/limited"

hr "3. Wait 4s for the bucket to refill, then 3 more requests"
note "Should land all 3 × 200 because the bucket has ~4 tokens after the wait."
sleep 4
tally 3 "${DATA}/limited"

# ----------------------------------------------------------------------- #
hr "4. Inspect x-ratelimit-* response headers (DRAFT_VERSION_03)"
note "Refill again, then send 1 request and dump headers."
sleep 6
curl -sS -i "${DATA}/limited" 2>/dev/null \
  | head -20 \
  | grep -iE '^(HTTP|x-ratelimit-|x-envoy)' \
  | sed 's/^/    /' || true

# ----------------------------------------------------------------------- #
hr "5. /limited-custom — same bucket but custom over-limit response"
note "Refill, drain bucket with 5, then inspect the 6th (over-limit) response."
sleep 6
for _ in $(seq 1 5); do
  curl -sS -o /dev/null "${DATA}/limited-custom"
done
note "Response on the over-limit 6th request:"
curl -sS -i "${DATA}/limited-custom" 2>/dev/null \
  | head -12 \
  | grep -iE '^(HTTP|retry-after|x-rate-limit-|content-type|content-length):' \
  | sed 's/^/    /' || true

# ----------------------------------------------------------------------- #
hr "6. Stats — per-route counters live under {stat_prefix}.http_local_rate_limit.*"
curl -sS "${ADMIN}/stats?filter=http_local_rate_limit" | sort

hr "Done."
echo "Useful follow-ups:"
echo "  curl -s '${ADMIN}/stats?filter=limited\\.http_local_rate_limit' "
echo "  curl -s '${ADMIN}/stats?filter=limited_custom\\.http_local_rate_limit' "
