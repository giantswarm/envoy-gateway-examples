#!/usr/bin/env bash
#
# Exercises all three L4 route kinds. TCP and TLS go through
# kubectl port-forward; UDP doesn't (port-forward is TCP-only) so
# we test it from an ephemeral debug pod inside the cluster.

set -euo pipefail

NS=l4-demo
GATEWAY=l4
LOCAL_TCP=19001
LOCAL_TLS=18443
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
fail()  { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------- #
hr "1. Resource status — Gateway + 3 routes all Accepted/Programmed"

gw_prog=$(kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${gw_prog}" == "True" ]] && ok "Gateway/${GATEWAY} Programmed=True" \
                              || fail "Gateway not Programmed (got '${gw_prog:-<none>}')"

for entry in tcproute/tcp-echo udproute/coredns tlsroute/tls-backend; do
  acc=$(kubectl -n "${NS}" get "${entry}" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  [[ "${acc}" == "True" ]] && ok "${entry} Accepted=True" \
                            || fail "${entry} Accepted=${acc:-<none>}"
done

note "Per-listener status:"
kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{range .status.listeners[*]}    {.name}: attachedRoutes={.attachedRoutes} programmed={.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

# ----------------------------------------------------------------------- #
hr "2. TCPRoute — open a connection through Envoy to tcp-echo"

note "Port-forward localhost:${LOCAL_TCP} -> svc :9001"
kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_TCP}:9001" \
  >/tmp/l4-tcp-pf.log 2>&1 &
TCP_PF=$!
trap 'kill -TERM ${TCP_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  (echo > /dev/tcp/localhost/${LOCAL_TCP}) 2>/dev/null && break
  sleep 0.5
done

note "Send 'envoy-gateway' and read back — tcp-echo prefixes with 'hello '."
out=$(printf 'envoy-gateway\n' | nc -w 2 localhost ${LOCAL_TCP} || true)
echo "    reply: ${out}"
if echo "${out}" | grep -q "hello envoy-gateway"; then
  ok "TCPRoute round-trip works"
else
  warn "Unexpected reply — check 'make logs' and the tcp-echo image"
fi

# ----------------------------------------------------------------------- #
hr "3. TLSRoute — TLS handshake terminates AT THE BACKEND, not Envoy"

note "Port-forward localhost:${LOCAL_TLS} -> svc :8443"
kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_TLS}:8443" \
  >/tmp/l4-tls-pf.log 2>&1 &
TLS_PF=$!
trap 'kill -TERM ${TCP_PF} ${TLS_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  (echo > /dev/tcp/localhost/${LOCAL_TLS}) 2>/dev/null && break
  sleep 0.5
done

note "Inspect the cert chain — it should be SELF-SIGNED by tls.local, NOT signed"
note "by an Envoy-managed CA (because Envoy is passing the handshake through)."
subj=$(echo | openssl s_client \
         -connect "localhost:${LOCAL_TLS}" \
         -servername tls.local </dev/null 2>/dev/null \
       | openssl x509 -noout -subject -issuer 2>/dev/null || true)
echo "${subj}" | sed 's/^/    /'
if echo "${subj}" | grep -q "tls.local"; then
  ok "Backend's own self-signed cert is what the client sees"
else
  warn "subject parse failed; check raw with: openssl s_client -connect localhost:${LOCAL_TLS} -servername tls.local"
fi

note "Drive an HTTP request through the tunnel. --insecure since the cert is self-signed."
curl -sS --insecure \
  --resolve "tls.local:${LOCAL_TLS}:127.0.0.1" \
  "https://tls.local:${LOCAL_TLS}/" | sed 's/^/    /' || true

# ----------------------------------------------------------------------- #
hr "4. UDPRoute — dig CoreDNS through Envoy (in-cluster test)"

note "kubectl port-forward is TCP-only — we send a DNS query from an"
note "ephemeral pod inside the cluster instead. Target: svc/${SVC}:5353."
note "If the alpine image is slow to pull, this section can take 20-30s."

# Run a one-shot pod that does the dig and prints output. --restart=Never
# + --rm makes it ephemeral.
set +e
kubectl run -i --rm --tty=false --restart=Never \
  --image=docker.io/library/alpine:3.20 \
  -n "${NS}" dig-test-$$ \
  --command -- sh -c \
  "apk add --no-cache bind-tools >/dev/null 2>&1 && \
   echo '-- A demo.example.test --' && \
   dig +noall +answer +short @${SVC}.${EG_NS}.svc.cluster.local -p 5353 \
       demo.example.test A && \
   echo '-- A other.example.test --' && \
   dig +noall +answer +short @${SVC}.${EG_NS}.svc.cluster.local -p 5353 \
       other.example.test A" \
  2>&1 | sed 's/^/    /'
rc=$?
set -e
if [[ "${rc}" == "0" ]]; then
  ok "UDPRoute forwards DNS queries to CoreDNS"
else
  warn "dig test exited rc=${rc} — check 'kubectl -n ${NS} logs deploy/coredns'"
fi

# ----------------------------------------------------------------------- #
hr "5. Mapping — what did EG generate?"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/l4-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${TCP_PF} ${TLS_PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "Listeners — each route kind produces a different listener shape:"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | { name,
        port: .address.socket_address.port_value,
        protocol: .address.socket_address.protocol,
        listener_filters: [(.listener_filters // [])[].name],
        first_network_filter: ((.filter_chains // [])[0].filters[0].name // "n/a"),
        sni_match: (((.filter_chains // [])[0].filter_chain_match.server_names // [])[0] // "n/a")
      }]' | sed 's/^/    /'

cat <<'EOF' | sed 's/^/    /'

What you see above (filter the JSON for the values):

  port=9001 protocol=TCP  first_network_filter=envoy.filters.network.tcp_proxy
                          -> direct L4 forwarding, no HCM, no HTTP awareness.

  port=5353 protocol=UDP  the listener has UDP listener filters and the
                          network filter is udp_proxy (under .udp_listener_config
                          in newer Envoy; EG abstracts this).

  port=8443 protocol=TCP  first_network_filter=envoy.filters.network.tcp_proxy
                          BUT listener_filters=[tls_inspector] and
                          filter_chain_match.server_names=[tls.local] —
                          SNI peek + forward, no DownstreamTLS context.
EOF

# ----------------------------------------------------------------------- #
hr "6. Side-by-side mapping"

cat <<'EOF' | sed 's/^/    /'
Gateway API kind  Listener protocol      What Envoy does
---------------- ---------------------- -------------------------------------------
TCPRoute         TCP                    tcp_proxy network filter directly forwards
                                        the byte stream to a backend cluster
UDPRoute         UDP                    udp_proxy filter forwards each datagram
                                        to a backend; connection-less, no state
TLSRoute         TLS (Passthrough)      tls_inspector listener filter peeks SNI,
                                        filter_chain selected by server_names,
                                        tcp_proxy forwards the still-encrypted
                                        stream to the backend
HTTPRoute        HTTP / HTTPS           http_connection_manager + route table +
                                        L7 filter chain — covered in ex 01-04
GRPCRoute        HTTP / HTTPS           same HCM, route table matches on :path
                                        header — covered in ex 06
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make admin                                 # Envoy admin endpoint"
echo "  echo 'ping' | nc localhost ${LOCAL_TCP}    # raw TCP echo"
echo "  curl -k --resolve tls.local:${LOCAL_TLS}:127.0.0.1 https://tls.local:${LOCAL_TLS}/"
