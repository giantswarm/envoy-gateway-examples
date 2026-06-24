#!/usr/bin/env bash
#
# Drives traffic through both Backend CRs and dumps the slice of
# generated Envoy config that proves each one became a STRICT_DNS
# cluster (no EDS).

set -euo pipefail

NS=backend-demo
GATEWAY=backend-demo
LOCAL_PORT=18100
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
fail()  { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------- #
hr "1. Resource status — Backends + Gateway + HTTPRoute"

for b in example-com helloworld-fqdn; do
  st=$(kubectl -n "${NS}" get backend "${b}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  [[ "${st}" == "True" ]] && ok "Backend/${b} Accepted=True" \
                          || warn "Backend/${b} Accepted=${st:-<none>} — see 'make logs'"
done

gw_prog=$(kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${gw_prog}" == "True" ]] && ok "Gateway/${GATEWAY} Programmed=True" \
                              || fail "Gateway not Programmed (got '${gw_prog:-<none>}')"

rt_refs=$(kubectl -n "${NS}" get httproute backends \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
[[ "${rt_refs}" == "True" ]] && ok "HTTPRoute/backends ResolvedRefs=True" \
                              || fail "HTTPRoute backends not resolved (got '${rt_refs:-<none>}')"

# ----------------------------------------------------------------------- #
hr "2. Port-forward the data plane on :${LOCAL_PORT} (svc :80)"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/backend-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  (echo > /dev/tcp/localhost/${LOCAL_PORT}) 2>/dev/null && break
  sleep 0.5
done

# ----------------------------------------------------------------------- #
hr "3. /external -> Backend example-com (FQDN, external)"

note "GET /external — URL is rewritten to '/' before forwarding; Host is set to example.com."
note "Requires the cluster to have egress to the internet. If this hangs or 502s,"
note "your kind networking may be restricted — see README common failure modes."
set +e
out=$(curl -sS --max-time 10 -i "http://localhost:${LOCAL_PORT}/external" 2>&1)
rc=$?
set -e
if [[ "${rc}" == "0" ]]; then
  echo "${out}" | awk 'NR<=3 || /^HTTP|<title>|Example Domain/' | sed 's/^/    /'
  ok "external Backend reachable"
else
  warn "curl to /external failed (rc=${rc}) — likely egress restriction"
fi

# ----------------------------------------------------------------------- #
hr "4. /internal -> Backend helloworld-fqdn (in-cluster, .svc.cluster.local)"

note "GET /internal — URL is rewritten to '/' before forwarding."
note "helloworld is in the demo ns but addressed via FQDN here — NOT via Service ref,"
note "so no ReferenceGrant (example 08) is needed."
curl -sS --max-time 5 "http://localhost:${LOCAL_PORT}/internal" \
  | jq '{msg, from_}' | sed 's/^/    /'
ok "in-cluster FQDN Backend round-trip works"

# ----------------------------------------------------------------------- #
hr "5. Mapping — what kind of Envoy cluster does each Backend produce?"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/backend-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "Look for type: STRICT_DNS — that's the give-away. Service-backed routes use EDS."
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ClustersConfigDump"))
    | (.dynamic_active_clusters // [])[]
    | .cluster
    | select(.name | tostring | (test("example") or test("helloworld-fqdn")))
    | { name, type, dns_lookup_family: .dns_lookup_family,
        endpoints: [(.load_assignment.endpoints // [])[]
          | (.lb_endpoints // [])[]
          | (.endpoint.address.socket_address // null)] } ]' \
  | sed 's/^/    /'

cat <<'EOF' | sed 's/^/    /'

What you see above:

  type: STRICT_DNS               <-- Envoy re-resolves the hostname periodically.
                                     For Service-backed routes (ex 01-08), the
                                     equivalent field is "type: EDS".

  endpoints[].socket_address     <-- For FQDN backends this is the literal name
                                     and port from Backend.spec.endpoints[].fqdn.
                                     Envoy's DNS subsystem (c-ares) handles the
                                     actual IP resolution.

  no eds_cluster_config          <-- Confirms we're not using the Endpoint
                                     Discovery Service.
EOF

# ----------------------------------------------------------------------- #
hr "6. Side-by-side mapping"

cat <<'EOF' | sed 's/^/    /'
backendRef target                          Resulting Envoy cluster
------------------------------------------ ---------------------------------------
Service (group: "", kind: Service)         EDS cluster — endpoints from K8s
  -> (the default path, ex 01-08)            EndpointSlice; cross-ns needs RG

Backend (group: gateway.envoyproxy.io,
  kind: Backend) with endpoints[].fqdn     STRICT_DNS cluster — Envoy resolves
                                             the hostname periodically; no EDS

Backend with endpoints[].ip                STATIC cluster — single hard-coded
                                             socket_address; no DNS

Backend with endpoints[].unix              STATIC cluster — pipe address; useful
                                             for sidecar UDS scenarios
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make admin                              # Envoy admin endpoint"
echo "  curl -v http://localhost:${LOCAL_PORT}/external/"
echo "  curl http://localhost:${LOCAL_PORT}/internal/"
