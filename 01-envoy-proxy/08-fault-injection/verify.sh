#!/usr/bin/env bash
#
# Walk through delay + abort + probabilistic + header-driven faults.
# Total runtime ~10 seconds (mostly the 2s delays).

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

timed() {
  local label=$1 url=$2 ; shift 2
  local out
  out=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' "$@" "$url")
  printf "  %-32s HTTP %s in %ss\n" "$label" "${out%% *}" "${out##* }"
}

# Reset counters so the stats at the end are clean.
curl -sX POST "${ADMIN}/reset_counters" >/dev/null

# ----------------------------------------------------------------------- #
hr "1. /normal — control"
note "Filter is installed but the route does not opt in. Expect fast 200."
timed "GET /normal" "${DATA}/normal"

# ----------------------------------------------------------------------- #
hr "2. /delay — fixed 2s delay, 100%"
note "Every request waits exactly 2s before forwarding upstream."
timed "GET /delay" "${DATA}/delay"

# ----------------------------------------------------------------------- #
hr "3. /abort-100 — http_status 503, 100%"
note "No upstream hop; Envoy returns 503 directly. RESPONSE_FLAGS=FI in the access log."
timed "GET /abort-100" "${DATA}/abort-100"

# ----------------------------------------------------------------------- #
hr "4. /abort-25 — 25% probabilistic abort over 100 requests"
note "Expect roughly 25 of 100 to be 503; the rest 200."
for _ in $(seq 1 100); do
  curl -sS -o /dev/null -w '%{http_code}\n' "${DATA}/abort-25"
done | sort | uniq -c | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "5. /header — no fault headers"
note "Header-driven config; without the headers, request passes through."
timed "GET /header (no headers)" "${DATA}/header"

hr "6. /header — client-requested 1.5s delay"
note "x-envoy-fault-delay-request: 1500  (milliseconds)"
timed "GET /header (delay=1500)" "${DATA}/header" \
  -H "x-envoy-fault-delay-request: 1500"

hr "7. /header — client-requested 418 abort"
note "x-envoy-fault-abort-request: 418  (HTTP status)"
timed "GET /header (abort=418)" "${DATA}/header" \
  -H "x-envoy-fault-abort-request: 418"

hr "8. /header — both headers together"
note "Delay fires first, then abort. Total time ~= delay; final status = abort."
timed "GET /header (delay+abort)" "${DATA}/header" \
  -H "x-envoy-fault-delay-request: 1000" \
  -H "x-envoy-fault-abort-request: 503"

# ----------------------------------------------------------------------- #
hr "9. Fault filter stats"
note "Counters live under .fault.* per route. faults_injected, etc."
curl -sS "${ADMIN}/stats?filter=fault" | sort

hr "Done."
echo "Useful follow-up:"
echo "  curl -sS 'localhost:9901/stats?filter=fault'                   # per-event counters"
echo "  docker compose logs envoy | grep 'fault filter'                # debug-level traces"
