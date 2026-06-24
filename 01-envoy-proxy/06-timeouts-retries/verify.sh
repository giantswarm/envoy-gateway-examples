#!/usr/bin/env bash
#
# Walk through timeouts + retries. Some steps deliberately wait several
# seconds — that's the point (we're observing per_try_timeout and the
# overall route timeout). Expect a total runtime of about 30 seconds.

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"

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

# Helper: print HTTP status and wall-clock seconds for one curl.
timed() {
  local url=$1
  local code seconds
  read -r code seconds < <(
    curl -sS -o /tmp/tr.body \
         -w '%{http_code} %{time_total}\n' "$url"
  )
  printf "  HTTP %s in %ss\n" "$code" "$seconds"
}

# Helper: tally status codes across N requests.
tally() {
  local n=$1 url=$2
  for _ in $(seq 1 "$n"); do
    curl -sS -o /dev/null -w '%{http_code}\n' "$url"
  done | sort | uniq -c
}

stat() {
  curl -sS "${ADMIN}/stats?filter=$1" || true
}

# ----------------------------------------------------------------------- #
hr "1. /healthy — control. No timeout / no retry. Should be fast 200."
timed "${DATA}/healthy"

# ----------------------------------------------------------------------- #
hr "2. /strict?seconds=3 — route timeout 1s; backend sleeps 3s -> 504"
note "Expect 504 in about 1s (route timeout fires)."
timed "${DATA}/strict?seconds=3"
note "Access log will show RESPONSE_FLAGS containing UT (Upstream request Timeout)."

# ----------------------------------------------------------------------- #
hr "3. /strict-retry?seconds=3 — per_try_timeout 1s, num_retries 2"
note "Each try times out at 1s; Envoy retries twice; final 504 after ~3s."
timed "${DATA}/strict-retry?seconds=3"
note "Per-cluster retry stats (note upstream_rq_retry / upstream_rq_retry_overflow):"
stat 'cluster\.cluster_healthy\.upstream_rq_retry'

# ----------------------------------------------------------------------- #
hr "4. /flaky — no retry, 30 requests; expect ~10/30 to be 5xx"
note "Round-robin across 3 endpoints; one is hello-bad (always 503)."
tally 30 "${DATA}/flaky"

# ----------------------------------------------------------------------- #
hr "5. /flaky-retry — retry_on 5xx, num_retries 2, previous_hosts predicate"
note "Retry to a different host; expect ~100% 200s."
tally 30 "${DATA}/flaky-retry"
note "Per-cluster retry stats — upstream_rq_retry_success should be ~10:"
stat 'cluster\.cluster_flaky\.(upstream_rq_retry|upstream_rq_retry_success|upstream_rq_retry_overflow)'

# ----------------------------------------------------------------------- #
hr "Done."
echo "Useful follow-ups:"
echo "  watch -n1 \"curl -s '${ADMIN}/stats?filter=upstream_rq_retry'\""
echo "  curl -s '${ADMIN}/clusters?cluster=cluster_flaky' | grep -E 'hostname|::rq_total|::rq_error'"
