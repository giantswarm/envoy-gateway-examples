#!/usr/bin/env bash
#
# Confirms the Wasm filter ran on both request and response paths.

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"

hr()   { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note() { printf '   \033[2m%s\033[0m\n' "$*"; }

if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.
  make build-wasm               — build the filter first
  make up                       — start the stack
  docker compose logs envoy     — wasm load error?
EOF
  exit 1
fi

# ----------------------------------------------------------------------- #
hr "1. Regular request — Wasm adds x-wasm-filter to the response"
note "Backend serves normally; response carries the Wasm-added header."
curl -sS -i "${DATA}/anything" | head -12 | grep -iE '^(HTTP|x-wasm-filter|content-type)' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "2. Request with x-wasm-block — Wasm short-circuits with 403"
note "send_http_response inside the filter; never reaches the backend."
curl -sS -i -H 'x-wasm-block: yes' "${DATA}/anything" \
  | head -12 \
  | grep -iE '^(HTTP|x-wasm-filter|content-type|content-length)' \
  | sed 's/^/    /'
echo
note "Body:"
curl -sS -H 'x-wasm-block: yes' "${DATA}/anything" | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "3. x-wasm-greet log breadcrumb (info-level wasm log)"
note "Send a request; then check 'docker compose logs envoy' for the line."
curl -sS -o /dev/null -H 'x-wasm-greet: hi from verify' "${DATA}/anything"
echo "  (look for 'wasm log' in: docker compose logs envoy)"

# ----------------------------------------------------------------------- #
hr "4. Wasm filter stats"
note "Counters under wasm.<vm_id>.* and wasm.envoy.wasm.runtime.v8.*"
curl -sS "${ADMIN}/stats?filter=wasm" | sort | head -20

hr "Done."
echo "Useful follow-ups:"
echo "  docker compose logs envoy | grep -i wasm     # filter logs"
echo "  curl -s '${ADMIN}/clusters'                  # cluster status"
echo "  ls -lh ${PWD#/}/filter/target/wasm32-wasip1/release/hello_wasm.wasm"
