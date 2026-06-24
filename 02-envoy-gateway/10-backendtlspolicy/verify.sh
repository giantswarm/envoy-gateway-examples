#!/usr/bin/env bash
#
# Drives traffic through the Gateway and verifies that:
#   - With BackendTLSPolicy in place, the upstream connection is HTTPS
#     and Envoy validates the cert against the CA.
#   - Without the policy, Envoy can't talk to the HTTPS-only backend.

set -euo pipefail

NS=tls-upstream-demo
GATEWAY=secure-up
LOCAL_PORT=18110
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
sub()   { printf '\n\033[1;36m-- %s --\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
fail()  { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f certs/ca.crt ]] || fail "certs/ missing — run 'make up' first"

# ----------------------------------------------------------------------- #
hr "1. Resource status"

gw_prog=$(kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${gw_prog}" == "True" ]] && ok "Gateway/${GATEWAY} Programmed=True" \
                              || fail "Gateway not Programmed (got '${gw_prog:-<none>}')"

rt_refs=$(kubectl -n "${NS}" get httproute secure \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
[[ "${rt_refs}" == "True" ]] && ok "HTTPRoute/secure ResolvedRefs=True" \
                              || fail "HTTPRoute backend not resolved (got '${rt_refs:-<none>}')"

btp_acc=$(kubectl -n "${NS}" get backendtlspolicy secure-backend-tls \
  -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
[[ "${btp_acc}" == "True" ]] && ok "BackendTLSPolicy Accepted=True" \
                              || warn "BackendTLSPolicy Accepted=${btp_acc:-<none>} — see 'make logs'"

# ----------------------------------------------------------------------- #
hr "2. Port-forward + drive plaintext HTTP through the Gateway"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/btp-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  (echo > /dev/tcp/localhost/${LOCAL_PORT}) 2>/dev/null && break
  sleep 0.5
done

note "Client side is plain HTTP — but Envoy speaks HTTPS upstream."
curl -sS --max-time 5 "http://localhost:${LOCAL_PORT}/" | jq '.' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "3. /config_dump — upstream cluster has DownstreamTlsContext... wait, no"
note "   It's actually UpstreamTlsContext on the cluster. Look for transport_socket"
note "   with type UpstreamTlsContext on the secure-backend cluster:"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/btp-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ClustersConfigDump"))
    | (.dynamic_active_clusters // [])[]
    | .cluster
    | select(.name | tostring | test("secure-backend"))
    | { name,
        transport_socket: .transport_socket.name,
        sni: .transport_socket.typed_config.sni,
        common_tls_context_keys: ((.transport_socket.typed_config.common_tls_context // {}) | keys)
      }]' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "4. Negative — delete the BackendTLSPolicy, watch traffic fail"

sub "Deleting BackendTLSPolicy/secure-backend-tls..."
kubectl -n "${NS}" delete backendtlspolicy secure-backend-tls >/dev/null

# Give EG a moment to reconcile the cluster to plaintext.
sleep 3

note "Now Envoy tries plaintext HTTP/1.1 to nginx's TLS-only port. Expected"
note "responses, in rough order of likelihood:"
note "  400  nginx: 'The plain HTTP request was sent to HTTPS port' (most common)"
note "  502/503  Envoy: upstream_reset (TLS handshake failure surfaced as 5xx)"
note "  000 / ERR  curl: empty reply / connection error"
note "A 2xx would mean Envoy is STILL doing TLS somehow — investigate."
codes=""
for _ in $(seq 1 5); do
  c=$(curl -o /dev/null --silent --max-time 3 -w '%{http_code}' \
    "http://localhost:${LOCAL_PORT}/" 2>/dev/null || echo "ERR")
  codes="${codes}${c} "
done
echo "    response codes: ${codes}"
if echo "${codes}" | grep -qE '400|5[0-9][0-9]|000|ERR'; then
  ok "Upstream connection no longer works as HTTPS — BTP removal had the expected effect"
else
  warn "Got 2xx without BTP — investigate; the cluster may still have stale TLS config"
fi

sub "Re-applying the BackendTLSPolicy..."
kubectl apply -f manifests/backendtlspolicy.yaml >/dev/null
# Wait for the policy to be re-accepted.
for _ in $(seq 1 30); do
  st=$(kubectl -n "${NS}" get backendtlspolicy secure-backend-tls \
    -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  [[ "${st}" == "True" ]] && break
  sleep 1
done
sleep 2  # let EG push the cluster update

sub "Traffic should be 200s again:"
codes=""
for _ in $(seq 1 5); do
  c=$(curl -o /dev/null --silent --max-time 3 -w '%{http_code}' \
    "http://localhost:${LOCAL_PORT}/" 2>/dev/null || echo "ERR")
  codes="${codes}${c} "
done
echo "    response codes: ${codes}"

# ----------------------------------------------------------------------- #
hr "5. Side-by-side: downstream TLS (ex 05) vs upstream TLS (this example)"

cat <<'EOF' | sed 's/^/    /'
Direction        Configured by                        Envoy artifact
---------------- ------------------------------------ ----------------------------------
client -> Envoy  Gateway.listeners[].tls.certificate  Listener filter_chain transport_socket
   (downstream)    Refs + tls.mode (Terminate/         = DownstreamTlsContext
                   Passthrough). Example 05.

Envoy -> backend BackendTLSPolicy.spec.validation     Cluster transport_socket
   (upstream)      (caCertificateRefs OR               = UpstreamTlsContext
                   wellKnownCACertificates) +          (with sni + validation_context)
                   .hostname. This example.

End-to-end TLS   Both at once. Client speaks HTTPS    Listener uses DownstreamTlsContext,
                 to Gateway; Gateway terminates,      cluster uses UpstreamTlsContext.
                 then re-encrypts upstream.

True passthrough TLSRoute (example 07) — Envoy        No transport_socket on cluster;
                 never sees plaintext.                  pure TCP forwarding.
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make admin                   # Envoy admin endpoint"
echo "  curl http://localhost:${LOCAL_PORT}/"
echo "  kubectl -n ${NS} describe backendtlspolicy secure-backend-tls"
