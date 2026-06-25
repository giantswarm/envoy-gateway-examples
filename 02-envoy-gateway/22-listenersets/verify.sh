#!/usr/bin/env bash
#
# Confirms three listeners on ONE data plane, contributed by three
# different owners (platform + team-blue + team-green), and that
# each port routes to the right team's backend.

set -euo pipefail

NS_PLATFORM=platform
GATEWAY=shared
LOCAL_BASE=18220
LOCAL_BLUE=18221
LOCAL_GREEN=18222
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
sub()   { printf '\n\033[1;36m-- %s --\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
fail()  { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------- #
hr "1. Resource status — Gateway, both XListenerSets, both HTTPRoutes"

gw_prog=$(kubectl -n "${NS_PLATFORM}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${gw_prog}" == "True" ]] && ok "Gateway/${GATEWAY} Programmed=True" \
                              || fail "Gateway not Programmed (got '${gw_prog:-<none>}')"

XLS_RECONCILED=1
for entry in team-blue/blue team-green/green ; do
  ns=${entry%/*}; name=${entry#*/}
  acc=$(kubectl -n "${ns}" get xlistenerset "${name}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  reason=$(kubectl -n "${ns}" get xlistenerset "${name}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].reason}' 2>/dev/null || true)
  if [[ "${acc}" == "True" ]]; then
    ok "XListenerSet/${entry} Accepted=True"
  elif [[ "${reason}" == "Pending" ]]; then
    warn "XListenerSet/${entry} stuck at 'Waiting for controller' — EG doesn't watch XListenerSet yet at this version"
    XLS_RECONCILED=0
  else
    warn "XListenerSet/${entry} Accepted=${acc:-<none>} reason=${reason:-<none>}"
    XLS_RECONCILED=0
  fi
done

if [[ "${XLS_RECONCILED}" == "0" ]]; then
  cat <<'EOF' | sed 's/^/   /'

! KNOWN LIMITATION:
  The currently-installed Envoy Gateway version doesn't translate
  XListenerSets into Envoy listeners (the resource sits at
  conditions: Accepted=Unknown reason=Pending message='Waiting for
  controller'). Confirmed in EG v1.5.0.

  The CR shape, the multi-tenant pattern, and the route attachment
  via parentRefs[].kind: XListenerSet are all valid Gateway API
  experimental-channel — they're just waiting on EG to ship the
  data-plane wiring.

  Sections 3-5 below will fail accordingly. The example still
  documents the API surface you'll use once EG catches up. Try
  bumping EG_HELM_VERSION in ../00-kind-bootstrap/Makefile to a
  newer release if available.

EOF
fi

for entry in team-blue/blue team-green/green ; do
  ns=${entry%/*}; name=${entry#*/}
  acc=$(kubectl -n "${ns}" get httproute "${name}" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  [[ "${acc}" == "True" ]] && ok "HTTPRoute/${entry} Accepted=True" \
                            || warn "HTTPRoute/${entry} Accepted=${acc:-<none>}"
done

note "Listener-level view on the base Gateway (shows base + contributed):"
kubectl -n "${NS_PLATFORM}" get gateway "${GATEWAY}" \
  -o jsonpath='{range .status.listeners[*]}    {.name}: attachedRoutes={.attachedRoutes} programmed={.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'

# ----------------------------------------------------------------------- #
hr "2. Find the auto-generated data-plane Service (one for the WHOLE Gateway tree)"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

note "Service ports (one per listener — base + each XListenerSet):"
kubectl -n "${EG_NS}" get svc "${SVC}" \
  -o jsonpath='{range .spec.ports[*]}    {.name}: port={.port} targetPort={.targetPort}{"\n"}{end}'

# ----------------------------------------------------------------------- #
hr "3. Port-forward all three listener ports + curl each"

# Three port-forwards into the SAME svc.
kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_BASE}:80" \
  >/tmp/ls-base-pf.log 2>&1 &
PF_BASE=$!
kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_BLUE}:8080" \
  >/tmp/ls-blue-pf.log 2>&1 &
PF_BLUE=$!
kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_GREEN}:8081" \
  >/tmp/ls-green-pf.log 2>&1 &
PF_GREEN=$!
trap 'kill -TERM ${PF_BASE} ${PF_BLUE} ${PF_GREEN} 2>/dev/null || true' EXIT

wait_port() {
  local port=$1 pid=$2 logf=$3
  for _ in $(seq 1 30); do
    if (echo > /dev/tcp/localhost/${port}) 2>/dev/null; then return 0; fi
    if ! kill -0 ${pid} 2>/dev/null; then break; fi
    sleep 0.5
  done
  warn "port-forward never came up on :${port} (see ${logf})"
  return 1
}
wait_port ${LOCAL_BASE}  ${PF_BASE}  /tmp/ls-base-pf.log  && ok "base :${LOCAL_BASE}  live"
wait_port ${LOCAL_BLUE}  ${PF_BLUE}  /tmp/ls-blue-pf.log  && ok "blue :${LOCAL_BLUE}  live"
wait_port ${LOCAL_GREEN} ${PF_GREEN} /tmp/ls-green-pf.log && ok "green :${LOCAL_GREEN} live"

# ----------------------------------------------------------------------- #
hr "4. Hit each listener — distinct team responses"

sub "base (:${LOCAL_BASE}) — no route attached, expect 404 from Envoy"
curl -sS -o /tmp/ls-body --max-time 5 -w '%{http_code}\n' \
  "http://localhost:${LOCAL_BASE}/" \
  | xargs -I{} echo "    HTTP {}"

sub "blue listener (:${LOCAL_BLUE}) — team-blue backend"
curl -sS --max-time 5 "http://localhost:${LOCAL_BLUE}/" | jq . | sed 's/^/    /'

sub "green listener (:${LOCAL_GREEN}) — team-green backend"
curl -sS --max-time 5 "http://localhost:${LOCAL_GREEN}/" | jq . | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "5. /config_dump — one data plane, three listeners"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/ls-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF_BASE} ${PF_BLUE} ${PF_GREEN} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "Listeners — confirm 3 of them on the SAME Envoy pod:"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | { name, port: .address.socket_address.port_value }]' \
  | sed 's/^/    /'

note "Route configs — one per listener:"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | ((.dynamic_route_configs // []) + (.static_route_configs // []))[]
    | .route_config.name]' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "6. Mapping — XListenerSet to Envoy"

cat <<'EOF' | sed 's/^/    /'
Gateway API resource                    Envoy artifact
--------------------------------------- ----------------------------------------
Gateway (base) listener                 One Envoy listener
XListenerSet listener (each one)        Another Envoy listener on the SAME pod

allowedListeners.namespaces.from        Gateway-side admission gate for which
                                          namespaces' XListenerSets may attach.
                                          NOT a ReferenceGrant — the Gateway is
                                          the resource being "consumed".

HTTPRoute.parentRefs[]                  May point at the Gateway with sectionName,
                                          OR directly at the XListenerSet
                                          (group: gateway.networking.x-k8s.io,
                                           kind: XListenerSet). Both are valid.

Status                                  base Gateway's status.listeners[] shows
                                          ALL listeners (base + contributed),
                                          each with its own conditions and
                                          attachedRoutes count.

Data plane                              ONE Deployment + ONE Service per Gateway.
                                          Service exposes one port per listener
                                          (base + each XListenerSet's listener).
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make pf-base    # entry listener :${LOCAL_BASE}"
echo "  make pf-blue    # :${LOCAL_BLUE}  -> team-blue's nginx"
echo "  make pf-green   # :${LOCAL_GREEN} -> team-green's nginx"
echo "  make status     # base Gateway status + per-listener attachedRoutes"
echo "  kubectl get xlistenerset -A"
