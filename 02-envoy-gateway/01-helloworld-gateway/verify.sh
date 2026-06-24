#!/usr/bin/env bash
#
# Confirms the Gateway/HTTPRoute are programmed, drives traffic through
# the data plane via port-forward, and dumps the relevant slices of the
# generated Envoy config so the mapping to Phase 1 example 01 is visible.

set -euo pipefail

NS=demo
GATEWAY=eg

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
fail()  { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------- #
hr "1. Resource status — Gateway must be Programmed, HTTPRoute Accepted"

gw_prog=$(kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${gw_prog}" == "True" ]] && ok "Gateway/${GATEWAY} Programmed=True" \
                              || fail "Gateway not Programmed (got '${gw_prog:-<none>}')"

rt_acc=$(kubectl -n "${NS}" get httproute helloworld \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
[[ "${rt_acc}" == "True" ]] && ok "HTTPRoute/helloworld Accepted=True" \
                             || fail "HTTPRoute not Accepted (got '${rt_acc:-<none>}')"

rt_refs=$(kubectl -n "${NS}" get httproute helloworld \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
[[ "${rt_refs}" == "True" ]] && ok "HTTPRoute/helloworld ResolvedRefs=True" \
                              || fail "HTTPRoute backendRefs unresolved (got '${rt_refs:-<none>}')"

# ----------------------------------------------------------------------- #
hr "2. Locate the auto-generated data plane"

SVC=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY},gateway.envoyproxy.io/owning-gateway-namespace=${NS} \
  -o jsonpath='{.items[0].metadata.name}')
POD=$(kubectl -n envoy-gateway-system get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY},gateway.envoyproxy.io/owning-gateway-namespace=${NS} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: envoy-gateway-system/${SVC}"
ok "Envoy Pod:     envoy-gateway-system/${POD}"

# ----------------------------------------------------------------------- #
hr "3. Port-forward the data plane and drive traffic"

# Port-forward in the background; clean up on exit no matter how we leave.
kubectl -n envoy-gateway-system port-forward "svc/${SVC}" 8080:80 \
  >/tmp/hg-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT

# Wait for the local listener to be live.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:8080/ && break
  sleep 0.5
done

note "Single request:"
curl -sS http://localhost:8080/ | jq '{msg, from_}'

note "10 requests — distributed across the 3 helloworld replicas:"
for _ in $(seq 1 10); do
  curl -sS http://localhost:8080/ | jq -r .from_
done | sort | uniq -c | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "4. Mapping — what did Envoy Gateway translate this into?"

note "We'll dump the generated Envoy config via the admin port and pull"
note "out the listener / route / cluster sections."

# Reuse the existing port-forward to admin:19000. Start another one
# specifically for the admin port.
kubectl -n envoy-gateway-system port-forward "${POD}" 19000:19000 \
  >/tmp/hg-admin-pf.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT

for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump)

note "Listeners (dynamic):"
echo "${DUMP}" | jq '.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | {name, "address": .address.socket_address}' | sed 's/^/    /'

note "Routes (just route names + virtual_hosts):"
# Defensive: dynamic_route_configs may be absent / null until RDS converges,
# and routes can also live in static_route_configs. Use `?` and `// []`
# everywhere so a missing field doesn't kill the script.
echo "${DUMP}" | jq '[
    .configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | ( (.dynamic_route_configs // []) + (.static_route_configs // []) )[]
    | .route_config
    | {name, virtual_hosts: [ (.virtual_hosts // [])[] | {name, domains} ] }
  ]' | sed 's/^/    /'

note "Clusters that came from our HTTPRoute (filter by name prefix):"
echo "${DUMP}" | jq '[
    .configs[]?
    | select(."@type"|endswith("ClustersConfigDump"))
    | (.dynamic_active_clusters // [])[]
    | select(.cluster.name | tostring | test("helloworld"))
    | .cluster | {name, type, "endpoints_via": "EDS"}
  ]' | sed 's/^/    /'

# Stash the full dump so you can grep it later without standing up
# another port-forward.
echo "${DUMP}" > envoy-config.expected.json
ok "Full live config snapshotted to ./envoy-config.expected.json"

# ----------------------------------------------------------------------- #
hr "5. Compare with Phase 1 example 01"

cat <<EOF | sed 's/^/    /'
Phase 1 envoy.yaml             Phase 2 CR
---------------------------    ------------------------------------
listeners[].name               Gateway.metadata.name + listener
listeners[].address.port_value Gateway.spec.listeners[].port
filter_chains.filters HCM      auto-generated by EG
route_config.virtual_hosts[]   HTTPRoute.spec.hostnames + parentRefs
routes[].match.prefix          HTTPRoute.spec.rules[].matches[].path
routes[].route.cluster         HTTPRoute.spec.rules[].backendRefs (->EDS cluster)
clusters[]                     Service + EndpointSlice in the demo ns
type: STRICT_DNS               type: EDS (xDS-driven)
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make status                    # all conditions + the auto-generated pods"
echo "  make pf                        # port-forward the data plane interactively"
echo "  make admin                     # port-forward the Envoy admin endpoint"
echo "  jq . envoy-config.expected.json | less"
