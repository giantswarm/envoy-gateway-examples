#!/usr/bin/env bash
#
# Exercises both ReferenceGrant edges, then demonstrates the dynamic
# effect: delete a grant -> ResolvedRefs flips to RefNotPermitted ->
# re-apply -> recovery. Drives HTTPS traffic through the Gateway in
# `apps` to the helloworld backend in `demo`.

set -euo pipefail

NS=apps
BACKEND_NS=demo
GATEWAY=crossns
LOCAL_PORT=18443
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
sub()   { printf '\n\033[1;36m-- %s --\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
fail()  { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f certs/apps.local.crt ]] || fail "certs/ missing — run 'make up' first"

# ----------------------------------------------------------------------- #
hr "1. Two ReferenceGrants are in place in '${BACKEND_NS}'"

kubectl -n "${BACKEND_NS}" get referencegrant \
  -o jsonpath='{range .items[*]}  {.metadata.name}: from {.spec.from[0].kind}/{.spec.from[0].namespace} -> to {.spec.to[0].kind}/{.spec.to[0].name}{"\n"}{end}' \
  | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "2. Resource status — both cross-ns edges resolved"

gw_prog=$(kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${gw_prog}" == "True" ]] && ok "Gateway/${GATEWAY} Programmed=True" \
                              || fail "Gateway not Programmed (got '${gw_prog:-<none>}')"

l_refs=$(kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.listeners[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
[[ "${l_refs}" == "True" ]] && ok "Listener https ResolvedRefs=True (cert reachable)" \
                             || fail "Listener cert not resolved (got '${l_refs:-<none>}')"

rt_refs=$(kubectl -n "${NS}" get httproute app \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
[[ "${rt_refs}" == "True" ]] && ok "HTTPRoute/app ResolvedRefs=True (backend reachable)" \
                              || fail "HTTPRoute backend not resolved (got '${rt_refs:-<none>}')"

# ----------------------------------------------------------------------- #
hr "3. Drive HTTPS through the cross-namespace Gateway"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY},gateway.envoyproxy.io/owning-gateway-namespace=${NS} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:443" \
  >/tmp/refgrant-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if (echo | openssl s_client -connect "localhost:${LOCAL_PORT}" -servername apps.local </dev/null) \
       >/dev/null 2>&1; then break ; fi
  sleep 0.5
done

note "GET https://apps.local/ via --resolve to localhost:${LOCAL_PORT}"
curl -sS --cacert certs/apps.local.crt \
  --resolve "apps.local:${LOCAL_PORT}:127.0.0.1" \
  "https://apps.local:${LOCAL_PORT}/" | jq '{msg, from_}' | sed 's/^/    /'
ok "Cross-namespace HTTPS round-trip works (Gateway in apps, backend in demo)"

# ----------------------------------------------------------------------- #
hr "4. Dynamic flip — delete the Service RG, watch ResolvedRefs go False"

sub "Deleting ReferenceGrant httproute-to-services in ${BACKEND_NS}..."
kubectl -n "${BACKEND_NS}" delete referencegrant httproute-to-services >/dev/null

sub "Waiting for HTTPRoute ResolvedRefs to flip to False (up to 30s)..."
for _ in $(seq 1 60); do
  st=$(kubectl -n "${NS}" get httproute app \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
  rs=$(kubectl -n "${NS}" get httproute app \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].reason}' 2>/dev/null || true)
  msg=$(kubectl -n "${NS}" get httproute app \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].message}' 2>/dev/null || true)
  if [[ "${st}" == "False" ]]; then
    ok "ResolvedRefs=False reason: ${rs}"
    note "message: ${msg}"
    break
  fi
  sleep 0.5
done
[[ "${st}" == "False" ]] || warn "Did not flip to False within 30s — check controller logs"

sub "Confirming the data plane no longer reaches helloworld:"
# A few requests; expect 500 / no_healthy_upstream / 404 — anything non-200.
codes=""
for _ in $(seq 1 5); do
  c=$(curl -o /dev/null --silent --max-time 2 -w '%{http_code}' \
    --cacert certs/apps.local.crt \
    --resolve "apps.local:${LOCAL_PORT}:127.0.0.1" \
    "https://apps.local:${LOCAL_PORT}/" 2>/dev/null || echo "ERR")
  codes="${codes}${c} "
done
echo "    response codes: ${codes}"
if echo "${codes}" | grep -qE '500|503|000|ERR'; then
  ok "Traffic is rejected after RG was removed"
else
  warn "Traffic still got a 2xx — EG may not have reconciled yet, retry verify"
fi

# ----------------------------------------------------------------------- #
hr "5. Re-apply the RG, watch recovery"

kubectl apply -f manifests/refgrant-service.yaml >/dev/null
sub "Waiting for HTTPRoute ResolvedRefs to come back True..."
for _ in $(seq 1 60); do
  st=$(kubectl -n "${NS}" get httproute app \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
  [[ "${st}" == "True" ]] && break
  sleep 0.5
done
[[ "${st}" == "True" ]] && ok "ResolvedRefs=True again" \
                         || fail "Still not True after 30s; debug with 'make logs'"

sub "Re-driving traffic — should be 200s again:"
codes=""
for _ in $(seq 1 5); do
  c=$(curl -o /dev/null --silent --max-time 2 -w '%{http_code}' \
    --cacert certs/apps.local.crt \
    --resolve "apps.local:${LOCAL_PORT}:127.0.0.1" \
    "https://apps.local:${LOCAL_PORT}/")
  codes="${codes}${c} "
done
echo "    response codes: ${codes}"

# ----------------------------------------------------------------------- #
hr "6. Side-by-side: cross-namespace edges and their guards"

cat <<'EOF' | sed 's/^/    /'
Cross-namespace edge                           Requires a ReferenceGrant in...
---------------------------------------------- ---------------------------------------
Gateway.spec.listeners[].tls.certificateRefs[]  the Secret's namespace (here: demo),
  -> Secret/<other-ns>                          allowing kind=Gateway from this ns

HTTPRoute.spec.rules[].backendRefs[]            the Service's namespace (here: demo),
  -> Service/<other-ns>                         allowing kind=HTTPRoute from this ns

GRPCRoute, TCPRoute, TLSRoute, UDPRoute         same idea — RG must be in the target
  -> Service/<other-ns>                         namespace, kind matches the route kind

Gateway listener attachment from other ns       NOT a ReferenceGrant — controlled by
  (HTTPRoute lives in ns A, attaches to Gateway   Gateway.spec.listeners[].allowedRoutes
   in ns B)                                       .namespaces.{from,selector} on the
                                                  Gateway side. The Gateway is the
                                                  resource being "consumed" here.
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make status                                  # all CRs + the RGs"
echo "  kubectl -n ${BACKEND_NS} get referencegrant"
echo "  kubectl -n ${NS} describe httproute app      # look at the conditions"
