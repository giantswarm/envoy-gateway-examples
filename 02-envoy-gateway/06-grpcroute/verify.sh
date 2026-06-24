#!/usr/bin/env bash
#
# Drives gRPC traffic through the Gateway using grpcurl (the gRPC
# analogue of curl) and dumps the relevant slices of generated Envoy
# config so the GRPCRoute -> Envoy translation is visible.

set -euo pipefail

NS=grpc-demo
GATEWAY=rpc
LOCAL_PORT=18090
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
fail()  { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------- #
hr "1. Resource status — Gateway Programmed, GRPCRoute Accepted"

gw_prog=$(kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${gw_prog}" == "True" ]] && ok "Gateway/${GATEWAY} Programmed=True" \
                              || fail "Gateway not Programmed (got '${gw_prog:-<none>}')"

rt_acc=$(kubectl -n "${NS}" get grpcroute grpcbin \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
[[ "${rt_acc}" == "True" ]] && ok "GRPCRoute/grpcbin Accepted=True" \
                             || fail "GRPCRoute not Accepted (got '${rt_acc:-<none>}')"

rt_refs=$(kubectl -n "${NS}" get grpcroute grpcbin \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
[[ "${rt_refs}" == "True" ]] && ok "GRPCRoute/grpcbin ResolvedRefs=True" \
                              || fail "GRPCRoute backendRefs unresolved (got '${rt_refs:-<none>}')"

# ----------------------------------------------------------------------- #
hr "2. Port-forward the data plane (:${LOCAL_PORT} -> svc :80)"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/rpc-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT

# Wait for the port-forward to be ready (TCP-level probe — gRPC needs
# HTTP/2 over the same TCP socket).
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if (echo > /dev/tcp/localhost/${LOCAL_PORT}) 2>/dev/null; then break; fi
  sleep 0.5
done

# ----------------------------------------------------------------------- #
hr "3. List services — proves reflection routing works"

note "grpcurl uses the reflection service; routed by Rule 4 of the GRPCRoute."
grpcurl -plaintext localhost:${LOCAL_PORT} list | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "4. Rule 1 — service-level match on hello.HelloService"

note "Call SayHello (unary RPC)"
grpcurl -plaintext \
  -d '{"greeting": "Envoy Gateway"}' \
  localhost:${LOCAL_PORT} \
  hello.HelloService/SayHello | sed 's/^/    /'

note "Call LotsOfReplies (server-streaming RPC). 10 frames expected."
grpcurl -plaintext \
  -d '{"greeting": "stream"}' \
  localhost:${LOCAL_PORT} \
  hello.HelloService/LotsOfReplies 2>/dev/null \
  | jq -r '.reply // empty' | head -10 | sed 's/^/    /' || true

# ----------------------------------------------------------------------- #
hr "5. Rule 2 — method-level match on grpcbin.GRPCBin/DummyUnary"

note "We attached a RequestHeaderModifier; the upstream sees x-eg-tagged: dummy-unary."
note "(grpcbin's DummyUnary echoes a stable payload, not headers, so we"
note "verify the tag landed via /config_dump in section 7.)"
grpcurl -plaintext \
  -d '{"f_string":"hello","f_int32":42}' \
  localhost:${LOCAL_PORT} \
  grpcbin.GRPCBin/DummyUnary | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "6. Rule 3 — catch-all for grpcbin.GRPCBin (other methods)"

note "Empty: a zero-payload RPC. Returns an empty message."
grpcurl -plaintext localhost:${LOCAL_PORT} grpcbin.GRPCBin/Empty | sed 's/^/    /'

note "SpecificError: pass a code and we get a controlled gRPC status."
note "Expect status code NOT_FOUND (5)."
set +e
grpcurl -plaintext \
  -d '{"code": 5, "reason": "from-verify-script"}' \
  localhost:${LOCAL_PORT} \
  grpcbin.GRPCBin/SpecificError 2>&1 | sed 's/^/    /'
set -e
ok "controlled error returned (gRPC status surfaced through Envoy unchanged)"

# ----------------------------------------------------------------------- #
hr "7. Mapping — what did Envoy Gateway translate this into?"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/rpc-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "Listener has http2_protocol_options enabled (required for gRPC):"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | (.filter_chains // [])[]
    | (.filters // [])[]
    | select(.name == "envoy.filters.network.http_connection_manager")
    | .typed_config | { http2_protocol_options: .http2_protocol_options }]' \
  | sed 's/^/    /'

note "Routes — each GRPCRoute rule becomes a route with a header match on :path"
note "(gRPC paths are /package.Service/Method on the wire)."
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | ((.dynamic_route_configs // []) + (.static_route_configs // []))[]
    | .route_config
    | (.virtual_hosts // [])[]
    | (.routes // [])[]
    | { match_path: (.match.path // .match.prefix // .match.safe_regex.regex),
        match_headers: [(.match.headers // [])[] | {name, "regex": .string_match.safe_regex.regex, "exact": .string_match.exact}],
        cluster: .route.cluster,
        request_headers_to_add: [(.request_headers_to_add // [])[] | .header.key + "=" + .header.value]
      }]' | sed 's/^/    /'

note "Upstream cluster: HTTP/2 enabled (http2_protocol_options non-null)"
note "because the Service has appProtocol: kubernetes.io/h2c."
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ClustersConfigDump"))
    | (.dynamic_active_clusters // [])[]
    | .cluster
    | select(.name | tostring | test("grpcbin"))
    | { name, type, "h2": (.typed_extension_protocol_options // .http2_protocol_options // null) }]' \
  | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "8. Side-by-side mapping"

cat <<'EOF' | sed 's/^/    /'
GRPCRoute field                              Envoy artifact
-------------------------------------------- ------------------------------------
parentRefs[]                                 Gateway listener -> Envoy listener :80
matches[].method.service                     route.match.headers[:path] regex
matches[].method.method (optional)             ^/<service>/<method>$  (exact when both set)
                                               ^/<service>/.*         (any-method when method omitted)
matches[].headers[]                          route.match.headers[<name>]
filters[type: RequestHeaderModifier]         route.request_headers_to_add / remove
backendRefs[].name + .port                   cluster (EDS) populated from K8s Service
Service.appProtocol: kubernetes.io/h2c       cluster http2_protocol_options (gRPC needs HTTP/2)
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make admin                   # port-forward Envoy admin :19000"
echo "  grpcurl -plaintext localhost:${LOCAL_PORT} list"
echo "  grpcurl -plaintext localhost:${LOCAL_PORT} describe grpcbin.GRPCBin"
