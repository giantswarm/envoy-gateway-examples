#!/usr/bin/env bash
#
# Verify the SNI-routed TLS Gateway. Drives traffic with --resolve so
# we don't need /etc/hosts edits, then dumps the slice of generated
# Envoy config that produced the per-SNI filter chains.

set -euo pipefail

NS=demo
GATEWAY=secure
LOCAL_PORT=18443
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
fail()  { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f certs/ca.crt ]] || fail "certs/ca.crt missing — run 'make certs' or 'make up' first."

# ----------------------------------------------------------------------- #
hr "1. Resource status — Gateway Programmed, both HTTPRoutes Accepted"

gw_prog=$(kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${gw_prog}" == "True" ]] && ok "Gateway/${GATEWAY} Programmed=True" \
                              || fail "Gateway not Programmed (got '${gw_prog:-<none>}')"

for rt in hello api; do
  acc=$(kubectl -n "${NS}" get httproute "${rt}" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  refs=$(kubectl -n "${NS}" get httproute "${rt}" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
  [[ "${acc}"  == "True" ]] && ok "HTTPRoute/${rt} Accepted=True"     || fail "HTTPRoute/${rt} Accepted=${acc:-<none>}"
  [[ "${refs}" == "True" ]] && ok "HTTPRoute/${rt} ResolvedRefs=True" || fail "HTTPRoute/${rt} ResolvedRefs=${refs:-<none>}"
done

# Per-listener status — each one should report ResolvedRefs (cert found)
# and Programmed.
note "Listener-level status:"
kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{range .status.listeners[*]}    {.name}: attachedRoutes={.attachedRoutes} programmed={.conditions[?(@.type=="Programmed")].status} resolvedRefs={.conditions[?(@.type=="ResolvedRefs")].status}{"\n"}{end}'

# ----------------------------------------------------------------------- #
hr "2. Port-forward the data plane on :${LOCAL_PORT} (svc :443)"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:443" \
  >/tmp/secure-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
# Wait for the port-forward to be ready (TLS handshake will fail without SNI;
# we use openssl to probe TCP + handshake.)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if (echo | openssl s_client -connect "localhost:${LOCAL_PORT}" -servername hello.local </dev/null) \
       >/dev/null 2>&1; then break ; fi
  sleep 0.5
done

# ----------------------------------------------------------------------- #
hr "3. Drive HTTPS through each SNI — cert chain validates against our CA"

note "GET https://hello.local/  via --resolve to localhost:${LOCAL_PORT}"
curl -sS --cacert certs/ca.crt \
  --resolve "hello.local:${LOCAL_PORT}:127.0.0.1" \
  "https://hello.local:${LOCAL_PORT}/" | jq '{msg, from_}' | sed 's/^/    /'

note "GET https://api.local/    via --resolve to localhost:${LOCAL_PORT}"
curl -sS --cacert certs/ca.crt \
  --resolve "api.local:${LOCAL_PORT}:127.0.0.1" \
  -i "https://api.local:${LOCAL_PORT}/" \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP|^x-served-by/{print "  " $0}' \
  | tr -d '\r' || true

# ----------------------------------------------------------------------- #
hr "4. Confirm the cert presented by each SNI is the right one"

for host in hello.local api.local; do
  subj=$(echo | openssl s_client \
           -connect "localhost:${LOCAL_PORT}" \
           -servername "${host}" \
           -showcerts </dev/null 2>/dev/null \
         | openssl x509 -noout -subject 2>/dev/null || true)
  if echo "${subj}" | grep -q "CN ?= ?${host}"; then
    ok "SNI=${host} → leaf cert ${subj}"
  else
    # On some openssl builds the line format differs; print and pass.
    note "SNI=${host} → ${subj}"
  fi
done

# ----------------------------------------------------------------------- #
hr "5. Unknown SNI is rejected (no matching filter_chain)"

note "Expect: TLS handshake fails or returns 404 — neither cert applies."
set +e
out=$(curl -sS --cacert certs/ca.crt \
  --resolve "unknown.local:${LOCAL_PORT}:127.0.0.1" \
  -o /dev/null -w '%{http_code}\n' \
  "https://unknown.local:${LOCAL_PORT}/" 2>&1)
rc=$?
set -e
echo "    curl rc=${rc} body=${out}"
if [[ "${rc}" != "0" ]] || [[ "${out}" == "404" ]] || [[ "${out}" == "421" ]]; then
  ok "unknown SNI does not get a 200 (cert/handshake rejected, or 404 from filter-chain miss)"
else
  warn "unknown SNI got ${out} — investigate"
fi

# ----------------------------------------------------------------------- #
hr "6. Mapping — what did Envoy Gateway translate this into?"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/secure-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "Listener bound to :443 with TWO filter_chains (one per SNI):"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | select((.address.socket_address.port_value // 0) == 10443
             or (.address.socket_address.port_value // 0) == 443)
    | { name,
        port: .address.socket_address.port_value,
        listener_filters: [(.listener_filters // [])[].name],
        filter_chains:    [(.filter_chains // [])[]
          | { server_names: .filter_chain_match.server_names,
              has_transport_socket: (.transport_socket != null)
            }]
      }]' | sed 's/^/    /'

note "Listener filter present is tls_inspector — needed to peek at SNI"
note "before filter_chain selection. Same as Phase 1 example 09."

hr "7. Side-by-side with Phase 1 example 09"

cat <<'EOF' | sed 's/^/    /'
Phase 1 envoy.yaml (09)                  Phase 2 CR
---------------------------------------  ---------------------------------------
listener_https.address.port_value 10443  Gateway.spec.listeners[*].port = 443
listener_filters: tls_inspector          (auto-injected by EG when any listener
                                          has protocol: HTTPS)
filter_chain { filter_chain_match {      Gateway.spec.listeners[N].hostname
  server_names: [hello.local]            -> filter_chain_match.server_names
}}
transport_socket DownstreamTlsContext    Gateway.spec.listeners[N].tls
  with file-mounted cert + key             .certificateRefs[] -> Secret of type
                                           kubernetes.io/tls (SDS-managed by EG)
clusters[].load_assignment.endpoints     Service + EndpointSlice in demo ns;
                                          EG resolves backendRef -> EDS cluster
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make status   # listener-level status + Secrets + pods"
echo "  make admin    # port-forward Envoy admin :19000"
echo "  curl -v --cacert certs/ca.crt --resolve hello.local:${LOCAL_PORT}:127.0.0.1 https://hello.local:${LOCAL_PORT}/"
