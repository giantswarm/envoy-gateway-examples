#!/usr/bin/env bash
#
# Exercises every rule in the HTTPRoute and the separate api-local
# HTTPRoute. Mirrors Phase 1 example 03's verify.sh.

set -euo pipefail

NS=demo
GATEWAY=routing

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }

SVC=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${SVC}" ]]; then
  echo "ERROR: no data-plane service for Gateway/${GATEWAY}. Run 'make up' first." >&2
  exit 1
fi

# Port-forward the data plane once; reuse for the whole script.
kubectl -n envoy-gateway-system port-forward "svc/${SVC}" 8080:80 \
  >/tmp/routing-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:8080/ && break
  sleep 0.5
done

DATA="http://localhost:8080"

# Helper: print status + body's "path" (when JSON from /echo).
show() {
  local out status path
  out=$(curl -sS -i -o /tmp/r.body -w '%{http_code}' "$@")
  status=$out
  path=$(jq -r '.path // empty' /tmp/r.body 2>/dev/null || true)
  echo "  HTTP ${status}"
  if [[ -n "${path}" ]]; then
    note "backend saw path: ${path}"
  else
    note "body: $(head -1 /tmp/r.body 2>/dev/null || true)"
  fi
}

show_redirect() {
  echo
  curl -sS -o /dev/null -D - "$@" \
    | awk 'BEGIN{IGNORECASE=1} /^HTTP|^location/ {print "  " $0}' \
    | tr -d '\r'
}

# ----------------------------------------------------------------------- #
hr "1. URLRewrite — /api/v1/echo => backend /echo"
show "${DATA}/api/v1/echo"

hr "2. RequestRedirect — /legacy/anything => 301 to /api/v1"
show_redirect "${DATA}/legacy/anything"

hr "3. Header-gated — /admin/secret without x-api-key falls through to catch-all"
note "Catch-all route 6 takes over; backend sees /admin/secret unchanged (404 from helloworld)."
show "${DATA}/admin/secret"

hr "4. Header-gated — /admin/secret WITH x-api-key: hunter2 => backend /echo"
show -H 'x-api-key: hunter2' "${DATA}/admin/secret"

hr "5. Query-param match + header injection — /q?debug=true => backend /echo with x-debug"
curl -sS -H 'host: ignore' "${DATA}/q?debug=true" \
  | jq '{path, args, "x_debug": .headers["X-Debug"]}'

hr "6. Regex match — /users/42 => backend /echo"
show "${DATA}/users/42"

hr "7. Regex non-match — /users/abc falls through to catch-all"
note "Catch-all forwards as-is; helloworld returns 404 for unknown path."
show "${DATA}/users/abc"

hr "8. Hostname-scoped route — Host: api.local"
note "Separate HTTPRoute attached to the same Gateway."
show -H 'Host: api.local' "${DATA}/anything"

hr "9. Catch-all — / => backend /"
show "${DATA}/"

# ----------------------------------------------------------------------- #
hr "10. Mapping — how each filter shows up in generated Envoy config"
note "Open a separate port-forward to admin port and pull the route table:"
echo "  make admin                            # in another terminal"
echo "  curl -s localhost:19000/config_dump \\"
echo "    | jq '.configs[] | select(.\"@type\"|endswith(\"RoutesConfigDump\"))"
echo "                     | .dynamic_route_configs[].route_config.virtual_hosts'"

hr "Done."
