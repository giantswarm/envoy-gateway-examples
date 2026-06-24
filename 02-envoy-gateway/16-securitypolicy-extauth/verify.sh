#!/usr/bin/env bash
#
# Exercises the extAuth policy via the toy authz service:
#   /admin/*       requires x-user-role: admin
#   /protected/*   requires non-empty x-user-id
#   anything else  allowed
# Plus the failOpen test: kill authz and watch traffic fail-CLOSED.

set -euo pipefail

NS=demo
GATEWAY=extauth-gateway
LOCAL_PORT=18170
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
sub()   { printf '\n\033[1;36m-- %s --\033[0m\n' "$*"; }
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

sp_acc=$(kubectl -n "${NS}" get securitypolicy extauth-protect \
  -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
[[ "${sp_acc}" == "True" ]] && ok "SecurityPolicy Accepted=True" \
                              || warn "SecurityPolicy Accepted=${sp_acc:-<none>}"

authz_ready=$(kubectl -n "${NS}" get deploy authz \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[[ "${authz_ready}" == "1" ]] && ok "authz Deployment ready" \
                              || warn "authz Deployment not ready (${authz_ready}/1)"

# ----------------------------------------------------------------------- #
hr "2. Port-forward"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/extauth-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT

pf_ready=""
for _ in $(seq 1 30); do
  if (echo > /dev/tcp/localhost/${LOCAL_PORT}) 2>/dev/null; then pf_ready=1; break; fi
  if ! kill -0 ${PF} 2>/dev/null; then break; fi
  sleep 0.5
done
[[ -n "${pf_ready}" ]] || fail "port-forward never came up on :${LOCAL_PORT} (check /tmp/extauth-pf.log)"
ok "port-forward live on localhost:${LOCAL_PORT}"

check() {
  local label="$1" expected="$2"
  shift 2
  local code
  code=$(curl -sS -o /tmp/extauth-body --max-time 5 -w '%{http_code}' "$@" \
    "http://localhost:${LOCAL_PORT}/echo" || echo "ERR")
  if [[ "${code}" == "${expected}" ]]; then
    ok "${label}: HTTP ${code} (expected)"
  else
    warn "${label}: HTTP ${code} (expected ${expected})"
    head -1 /tmp/extauth-body 2>/dev/null | sed 's/^/        /' | cut -c1-160
  fi
}

# ----------------------------------------------------------------------- #
hr "3. Unmetered path -> 200"

note "Authz allows any path that's not /admin or /protected."
check "GET /echo (unmetered)" 200

# ----------------------------------------------------------------------- #
hr "4. /protected — missing x-user-id -> 401"

URL_PROT="http://localhost:${LOCAL_PORT}/protected/foo"
code=$(curl -sS -o /tmp/extauth-body --max-time 5 -w '%{http_code}' "${URL_PROT}" || echo "ERR")
echo "    HTTP ${code}"
if [[ "${code}" == "401" ]]; then ok "blocked as expected"; else warn "expected 401, got ${code}"; fi

# ----------------------------------------------------------------------- #
hr "5. /protected — with x-user-id -> 200, decision header propagated"

note "Backend should also see x-authz-decision (added by authz, forwarded by EG)"
curl -sS -H "x-user-id: alice" \
  "http://localhost:${LOCAL_PORT}/protected/profile" \
  | jq '{from_, path, x_user_id: .headers["X-User-Id"], x_authz_decision: .headers["X-Authz-Decision"]}' \
  | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "6. /admin — without admin role -> 403"

URL_ADMIN="http://localhost:${LOCAL_PORT}/admin/settings"
code=$(curl -sS -o /tmp/extauth-body --max-time 5 -w '%{http_code}' \
  -H "x-user-id: alice" "${URL_ADMIN}" || echo "ERR")
echo "    HTTP ${code}"
if [[ "${code}" == "403" ]]; then ok "blocked as expected (user but not admin)"; else warn "expected 403, got ${code}"; fi

# ----------------------------------------------------------------------- #
hr "7. /admin — with admin role -> 200"

curl -sS -H "x-user-role: admin" \
  "http://localhost:${LOCAL_PORT}/admin/settings" \
  | jq '{from_, path, x_authz_decision: .headers["X-Authz-Decision"]}' \
  | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "8. failOpen — stop authz, watch fail-CLOSED"

sub "Scaling authz to 0 replicas..."
kubectl -n "${NS}" scale deploy/authz --replicas=0 >/dev/null
kubectl -n "${NS}" wait --for=delete pod -l app=authz --timeout=30s >/dev/null 2>&1 || true
sleep 2   # let Envoy notice endpoints are gone

note "With failOpen: false (our config), Envoy should now block traffic."
codes=""
for _ in $(seq 1 5); do
  c=$(curl -o /dev/null --silent --max-time 3 -w '%{http_code}' \
    "http://localhost:${LOCAL_PORT}/echo" || echo "ERR")
  codes="${codes}${c} "
done
echo "    response codes (no authz): ${codes}"
if echo "${codes}" | grep -qE '403|503|500|000|ERR'; then
  ok "fail-closed working (non-2xx returned)"
else
  warn "expected non-2xx with authz down (failOpen=false); got: ${codes}"
fi

sub "Restoring authz..."
kubectl -n "${NS}" scale deploy/authz --replicas=1 >/dev/null
kubectl -n "${NS}" wait --for=condition=Available --timeout=60s deploy/authz >/dev/null
sleep 2
codes=""
for _ in $(seq 1 5); do
  c=$(curl -o /dev/null --silent --max-time 3 -w '%{http_code}' \
    "http://localhost:${LOCAL_PORT}/echo" || echo "ERR")
  codes="${codes}${c} "
done
echo "    response codes (authz back): ${codes}"

# ----------------------------------------------------------------------- #
hr "9. Mapping — what's in /config_dump"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/extauth-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "HCM filter list — envoy.filters.http.ext_authz should be present:"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | (.filter_chains // [])[]
    | (.filters // [])[]
    | select(.name == "envoy.filters.network.http_connection_manager")
    | (.typed_config.http_filters // [])[]
    | .name] | unique' | sed 's/^/    /'

note "ext_authz config — cluster pointer + failure_mode_allow:"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | (.filter_chains // [])[]
    | (.filters // [])[]
    | select(.name == "envoy.filters.network.http_connection_manager")
    | (.typed_config.http_filters // [])[]
    | select(.name | tostring | test("ext_authz"))
    | .typed_config
    | { failure_mode_allow,
        http_service: {
          cluster: .http_service.server_uri.cluster,
          timeout: .http_service.server_uri.timeout
        },
        authorization_response: .http_service.authorization_response
      }]' | sed 's/^/    /'

hr "Done."
echo "Useful follow-ups:"
echo "  curl -i -H 'x-user-id: alice' http://localhost:${LOCAL_PORT}/protected/foo"
echo "  curl -i -H 'x-user-role: admin' http://localhost:${LOCAL_PORT}/admin/settings"
echo "  kubectl -n ${NS} logs deploy/authz --tail=20         # see authz's view of requests"
