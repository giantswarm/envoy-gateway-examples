#!/usr/bin/env bash
#
# Generate a mix of normal / slow / error traffic, then inspect each of
# the three access log sinks.

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"
LOG_DIR="$(cd "$(dirname "$0")" && pwd)/logs"

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

# Start fresh: truncate the file sinks so the JSON / errors lines below
# come from this run only.
: > "${LOG_DIR}/access.json" 2>/dev/null || true
: > "${LOG_DIR}/errors.log"  2>/dev/null || true

# ----------------------------------------------------------------------- #
hr "1. Generate traffic"
note "Five 200s, two 503s, one slow request."
for _ in 1 2 3 4 5; do
  curl -sS -o /dev/null "${DATA}/"
done
for _ in 1 2; do
  curl -sS -o /dev/null "${DATA}/fail?code=503"
done
curl -sS -o /dev/null "${DATA}/slow?seconds=1"

# Give Envoy a moment to flush file logs.
sleep 1

# ----------------------------------------------------------------------- #
hr "2. Sink 1 — stdout (custom text format)"
note "Latest 8 lines from the envoy container's stdout."
docker compose logs envoy --tail 8 | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "3. Sink 2 — file ./logs/access.json (JSON, every request)"
note "One JSON object per line; pretty-printed via jq."
if [[ -s "${LOG_DIR}/access.json" ]]; then
  cat "${LOG_DIR}/access.json" | jq -c . | head -8 | sed 's/^/    /'
  echo
  note "Fields available (decoded from the last line):"
  tail -1 "${LOG_DIR}/access.json" | jq . | sed 's/^/    /'
else
  echo "    (empty — check permissions on ./logs/)"
fi

# ----------------------------------------------------------------------- #
hr "4. Sink 3 — file ./logs/errors.log (text, ONLY 5xx)"
note "Filter status_code_filter { GE 500 } keeps everything else out."
if [[ -s "${LOG_DIR}/errors.log" ]]; then
  cat "${LOG_DIR}/errors.log" | sed 's/^/    /'
else
  echo "    (empty)"
fi

# ----------------------------------------------------------------------- #
hr "5. Flip the error-log threshold at runtime"
note "Default is 500; bumping to 400 will start logging 4xx too."
curl -sS -X POST "${ADMIN}/runtime_modify?access_log.errors.min_status=400" >/dev/null
echo "  threshold -> 400; sending a 401..."
curl -sS -o /dev/null "${DATA}/fail?code=401"
sleep 0.5
echo "  tail errors.log:"
tail -1 "${LOG_DIR}/errors.log" | sed 's/^/    /'
note "Reset to 500."
curl -sS -X POST "${ADMIN}/runtime_modify?access_log.errors.min_status=500" >/dev/null

hr "Done."
echo "Tail interactively:"
echo "  make tail-json     # jq-pretty"
echo "  make tail-errors   # plain text"
echo "  make traffic       # pump more requests"
