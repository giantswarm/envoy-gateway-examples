#!/usr/bin/env bash
#
# Exercises every route defined in envoy.yaml. After each request we print
# the relevant bits (status, redirect target, body's "path" field) so the
# match -> action -> transform chain is visible.

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"

hr()  { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note(){ printf '   \033[2m%s\033[0m\n' "$*"; }

# Precondition: Envoy admin reachable.
if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.
  1. make up                       — start the stack
  2. docker compose ps             — confirm containers are up
  3. docker compose logs envoy     — config rejected?
  4. lsof -i :10000 -i :9901       — port already in use?
EOF
  exit 1
fi

# Helper: print status line + body's "path" field (if any).
show() {
  local out status path
  out=$(curl -sS -i -o /tmp/verify.body -w '%{http_code}' "$@") || true
  status=$out
  path=$(jq -r '.path // empty' /tmp/verify.body 2>/dev/null || true)
  echo "  HTTP ${status}"
  if [[ -n "$path" ]]; then
    note "backend saw path: ${path}"
  else
    note "body: $(head -1 /tmp/verify.body || true)"
  fi
}

# Helper: show Location header for redirects.
show_redirect() {
  echo
  curl -sS -o /dev/null -D - "$@" \
    | awk 'BEGIN{IGNORECASE=1} /^HTTP|^location/ {print "  " $0}' \
    | tr -d '\r'
}

hr "1. Exact match + direct_response"
note "GET /healthz  -> Envoy answers itself, no backend hop"
curl -sS -i "${DATA}/healthz" | sed -n '1,3p;6,$p' | tr -d '\r'

hr "2. Prefix rewrite"
note "GET /api/v1/echo  -> backend sees /echo (prefix /api/v1/ replaced by /)"
show "${DATA}/api/v1/echo"

hr "3. Redirect"
note "GET /legacy/anything  -> 301 to /api/v1"
show_redirect "${DATA}/legacy/anything"

hr "4. Header-gated route — denied (no header)"
note "GET /admin/secret  -> falls through to the 401 route"
show "${DATA}/admin/secret"

hr "5. Header-gated route — allowed"
note "GET /admin/secret with x-api-key: hunter2  -> backend /echo"
show -H "x-api-key: hunter2" "${DATA}/admin/secret"

hr "6. Query-param match + request_headers_to_add"
note "GET /q?debug=true  -> backend /echo, x-debug header injected"
curl -sS "${DATA}/q?debug=true" \
  | jq '{path, args, "x_debug": .headers["X-Debug"]}'

hr "7. Catch-all"
note "GET /  -> backend /  (unrewritten root)"
show "${DATA}/"
note "GET /headers  -> backend /headers"
show "${DATA}/headers"

hr "8. Virtual host: api.local"
note "Host: api.local with any path  -> backend /echo (other vhost's rule)"
show -H "Host: api.local" "${DATA}/anything"

hr "Useful follow-ups"
echo "  watch -n1 \"curl -s '${ADMIN}/stats?filter=vhost'\""
echo "  curl -s ${ADMIN}/config_dump | jq '.configs[]|select(.\"@type\"|endswith(\"RoutesConfigDump\")).static_route_configs'"
