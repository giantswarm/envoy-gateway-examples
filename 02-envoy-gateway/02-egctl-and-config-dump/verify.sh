#!/usr/bin/env bash
#
# Tour the generated Envoy config the Envoy-Gateway way. Uses port-forward
# + curl by default; if you have `egctl` on PATH, the README shows the
# equivalent one-liners.

set -euo pipefail

NS=demo
GATEWAY=inspect

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
sub()   { printf '\n\033[1;36m-- %s --\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }

POD=$(kubectl -n envoy-gateway-system get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY},gateway.envoyproxy.io/owning-gateway-namespace=${NS} \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "${POD}" ]]; then
  echo "ERROR: no data-plane pod found for Gateway/${GATEWAY}. Run 'make up' first." >&2
  exit 1
fi

# Single port-forward to the admin endpoint; reused for the whole script.
kubectl -n envoy-gateway-system port-forward "${POD}" 19000:19000 \
  >/tmp/inspect-admin.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT

# Wait for the local listener.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready && break
  sleep 0.5
done

A="http://localhost:19000"

# Snapshot once; reuse for the per-section greps so we don't pummel the
# admin port.
DUMP=$(curl -sS "${A}/config_dump?include_eds")

# ----------------------------------------------------------------------- #
hr "1. Top of config_dump — what sections are present"
echo "${DUMP}" | jq '[.configs[]."@type"]' | sed 's/^/    /'
note "Each ConfigDump entry maps to an xDS resource type:"
cat <<'EOF' | sed 's/^/    /'
  BootstrapConfigDump      — what EG handed to envoy at startup
  ListenersConfigDump      — Listener Discovery Service (LDS)
  RoutesConfigDump         — Route Discovery Service (RDS)
  ClustersConfigDump       — Cluster Discovery Service (CDS)
  EndpointsConfigDump      — Endpoint Discovery Service (EDS) — only with ?include_eds
  SecretsConfigDump        — Secret Discovery Service (SDS) — TLS material
  EcdsConfigDump           — Extension Config Discovery Service (filters via xDS)
EOF

# ----------------------------------------------------------------------- #
hr "2. Listeners (LDS) — what Envoy is bound to"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | { name: .name,
        address: .active_state.listener.address.socket_address,
        filter_chains: ((.active_state.listener.filter_chains // []) | length),
        version_info: .active_state.version_info
      }]' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "3. Routes (RDS) — virtual hosts + routes for one listener"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | ((.dynamic_route_configs // []) + (.static_route_configs // []))[]
    | .route_config
    | { name: .name,
        virtual_hosts: [(.virtual_hosts // [])[] | {name, domains, n_routes: ((.routes // []) | length)}]
      }]' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "4. Clusters (CDS) — upstream pools"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ClustersConfigDump"))
    | (.dynamic_active_clusters // [])[]
    | { name: .cluster.name,
        type: .cluster.type,
        version_info: .version_info
      }] | .[0:40]' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "5. Endpoints (EDS) — what hosts are actually behind each cluster"
note "Only shows up because we asked for ?include_eds above."
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("EndpointsConfigDump"))
    | (.dynamic_endpoint_configs // [])[]
    | .endpoint_config
    | { cluster: .cluster_name,
        endpoints: [(.endpoints // [])[]
          | { locality: .locality,
              addresses: [(.lb_endpoints // [])[] | .endpoint.address.socket_address]
            }]
      }] | .[0:10]' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "6. xDS convergence — apply a new HTTPRoute and watch RDS update"
sub "version_info BEFORE"
echo "${DUMP}" | jq -r '[.configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | (.dynamic_route_configs // [])[0].version_info // "(no dynamic_route_configs yet)"][0]' \
  | sed 's/^/    /'

sub "Applying manifests/httproute-extra.yaml..."
kubectl apply -f manifests/httproute-extra.yaml >/dev/null
kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
  --timeout=30s -n ${NS} httproute/hello-extra >/dev/null

sleep 1
DUMP2=$(curl -sS "${A}/config_dump")
sub "version_info AFTER"
echo "${DUMP2}" | jq -r '[.configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | (.dynamic_route_configs // [])[0].version_info // "(no dynamic_route_configs yet)"][0]' \
  | sed 's/^/    /'

sub "New virtual_hosts (matched by domain)"
echo "${DUMP2}" | jq '[.configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | (.dynamic_route_configs // [])[]
    | (.route_config.virtual_hosts // [])[]
    | {name, domains}]' | sed 's/^/    /'

note "Cleaning up the extra HTTPRoute."
kubectl delete -f manifests/httproute-extra.yaml --ignore-not-found >/dev/null

# ----------------------------------------------------------------------- #
hr "7. Trace one request through the live config"
sub "Send a real request via the data plane (needs another port-forward)"
SVC=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY},gateway.envoyproxy.io/owning-gateway-namespace=${NS} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n envoy-gateway-system port-forward "svc/${SVC}" 8080:80 \
  >/tmp/inspect-data.log 2>&1 &
DATA_PF=$!
trap 'kill -TERM ${PF} ${DATA_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:8080/ && break
  sleep 0.5
done

REQ_ID=$(curl -sS -i http://localhost:8080/ | awk 'tolower($1)=="x-request-id:"{print $2}' | tr -d '\r')
note "x-request-id = ${REQ_ID}"

sub "Listener that accepted it (only one HTTP listener here)"
echo "${DUMP}" | jq -r '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[].name] | .[]' | sed 's/^/    /'

sub "Route picked (PathPrefix / → cluster)"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | (.dynamic_route_configs // [])[]
    | (.route_config.virtual_hosts // [])[0]
    | (.routes // [])[0]
    | { match: .match, route_cluster: .route.cluster }] | .[0]' | sed 's/^/    /'

sub "Cluster name resolved from backendRef"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ClustersConfigDump"))
    | (.dynamic_active_clusters // [])[]
    | .cluster
    | select(.name | tostring | test("helloworld"))
    | .name]' | sed 's/^/    /'

sub "Endpoints actually serving — note these are POD IPs (EDS)"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("EndpointsConfigDump"))
    | (.dynamic_endpoint_configs // [])[]
    | .endpoint_config
    | select((.cluster_name // "") | tostring | test("helloworld"))
    | (.endpoints // [])[]
    | (.lb_endpoints // [])[]
    | .endpoint.address.socket_address]' \
  | sed 's/^/    /'

sub "Search the access log for that request id"
kubectl -n envoy-gateway-system logs "${POD}" --tail=200 2>/dev/null \
  | grep -F "${REQ_ID}" | sed 's/^/    /' || echo "    (no match — try increasing --tail)"

hr "Done."
echo "Want a friendlier UX? Install egctl and try:"
echo "  egctl config envoy-proxy all     -n envoy-gateway-system"
echo "  egctl config envoy-proxy listener -n envoy-gateway-system"
echo "  egctl config envoy-proxy route    -n envoy-gateway-system"
echo "  egctl config envoy-proxy cluster  -n envoy-gateway-system"
echo "  egctl config envoy-proxy endpoint -n envoy-gateway-system"
echo "  egctl experimental translate --type gateway-api -f manifests/gateway.yaml -f manifests/httproute.yaml"
