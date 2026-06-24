#!/usr/bin/env bash
#
# Confirms both JSON patches landed in the generated Envoy config:
#   1. listener.per_connection_buffer_limit_bytes = 1048576
#   2. route_config has an x-patched-by response header
# And drives a request through, observing the header on the wire.

set -euo pipefail

NS=demo
GATEWAY=patched
LOCAL_PORT=18180
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
fail()  { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------- #
hr "1. Resource status"

gw_prog=$(kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${gw_prog}" == "True" ]] && ok "Gateway/${GATEWAY} Programmed=True" \
                              || fail "Gateway not Programmed (got '${gw_prog:-<none>}')"

epp_prog=$(kubectl -n "${NS}" get envoypatchpolicy patched \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${epp_prog}" == "True" ]] && ok "EnvoyPatchPolicy Programmed=True" \
                               || warn "EnvoyPatchPolicy Programmed=${epp_prog:-<none>}"

# ----------------------------------------------------------------------- #
hr "2. Port-forward + send a request, look at headers"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/epp-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
pf_ready=""
for _ in $(seq 1 30); do
  if (echo > /dev/tcp/localhost/${LOCAL_PORT}) 2>/dev/null; then pf_ready=1; break; fi
  if ! kill -0 ${PF} 2>/dev/null; then break; fi
  sleep 0.5
done
[[ -n "${pf_ready}" ]] || fail "port-forward never came up (see /tmp/epp-pf.log)"
ok "port-forward live on localhost:${LOCAL_PORT}"

note "GET / — expect 200 + x-patched-by: envoy-patch-policy in the response headers:"
curl -sS -i --max-time 5 "http://localhost:${LOCAL_PORT}/" \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP|^x-patched-by|^server|^content-type/{print "  " $0}' \
  | tr -d '\r' | head -8

# Strict check.
xph=$(curl -sS -D - -o /dev/null --max-time 5 "http://localhost:${LOCAL_PORT}/" \
  | awk 'BEGIN{IGNORECASE=1} /^x-patched-by:/{print $2}' | tr -d '\r')
if [[ "${xph}" == "envoy-patch-policy" ]]; then
  ok "Patch 2 confirmed — x-patched-by header injected"
else
  warn "no x-patched-by header (got '${xph}') — patch may not be applied yet, see 'make logs'"
fi

# ----------------------------------------------------------------------- #
hr "3. /config_dump — verify Patch 1 (listener per_connection_buffer_limit_bytes)"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/epp-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

buf=$(echo "${DUMP}" | jq -r '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | select(.name | tostring | test("patched"))
    | .per_connection_buffer_limit_bytes // empty][0]')
echo "    listener per_connection_buffer_limit_bytes: ${buf}"
if [[ "${buf}" == "1048576" ]]; then
  ok "Patch 1 confirmed — listener buffer bumped to 1 MiB"
else
  warn "expected 1048576, got '${buf}' — patch may not be applied"
fi

# ----------------------------------------------------------------------- #
hr "4. /config_dump — verify Patch 2 in the route_config"

echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | ((.dynamic_route_configs // []) + (.static_route_configs // []))[]
    | .route_config
    | select(.name | tostring | test("patched"))
    | { name,
        response_headers_to_add: [(.response_headers_to_add // [])[]
          | { key: .header.key, value: .header.value }]
      }]' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "5. Mapping — JSONPatch fields to Envoy artifacts"

cat <<'EOF' | sed 's/^/    /'
EnvoyPatchPolicy field        Meaning
----------------------------- --------------------------------------------------
spec.targetRef                The Gateway whose xDS resources we're patching
spec.type                     JSONPatch (RFC 6902) or Merge (whole-resource overlay)
spec.priority                 Order across multiple EPPs targeting same Gateway

spec.jsonPatches[].type       Proto type URL — picks WHICH xDS resource kind
   type.googleapis.com/...
     ...listener.v3.Listener
     ...route.v3.RouteConfiguration
     ...cluster.v3.Cluster
     ...endpoint.v3.ClusterLoadAssignment
     ...secret.v3.Secret
     ...bootstrap.v3.Bootstrap   (only with `type: ClusterPatch`)

spec.jsonPatches[].name       The resource's EG-assigned name:
                              listeners/routes:  <ns>/<gateway>/<listener-name>
                              clusters:          <ns>/<httproute>-rule-<i>
                                                 (also <ns>/<service>:<port>)

spec.jsonPatches[].operation  An RFC 6902 op:
   op:    add | remove | replace | move | copy | test
   path:  JSON Pointer (RFC 6901). `/-` means "append to array".
   value: the new value (any JSON; quoted string for scalars)
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  curl -i http://localhost:${LOCAL_PORT}/    # show the patched response headers"
echo "  make admin                                # full config_dump"
echo "  kubectl -n ${NS} describe envoypatchpolicy patched"
