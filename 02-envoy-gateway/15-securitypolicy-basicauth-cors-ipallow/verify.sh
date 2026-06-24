#!/usr/bin/env bash
#
# Exercises three SecurityPolicy sub-features:
#   - basicAuth: no creds, wrong creds, right creds
#   - authorization: allowed source IP (via XFF), denied source IP
#   - cors: preflight from allowed origin, preflight from denied origin
#
# Source IP for authorization checks comes from X-Forwarded-For
# (numTrustedHops=1 in the ClientTrafficPolicy).

set -euo pipefail

NS=demo
GATEWAY=security-mix
LOCAL_PORT=18160
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

sp_acc=$(kubectl -n "${NS}" get securitypolicy security-mix \
  -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
[[ "${sp_acc}" == "True" ]] && ok "SecurityPolicy Accepted=True" \
                              || warn "SecurityPolicy Accepted=${sp_acc:-<none>}"

ctp_acc=$(kubectl -n "${NS}" get clienttrafficpolicy security-mix-xff \
  -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
[[ "${ctp_acc}" == "True" ]] && ok "ClientTrafficPolicy Accepted=True" \
                              || warn "ClientTrafficPolicy Accepted=${ctp_acc:-<none>}"

# ----------------------------------------------------------------------- #
hr "2. Port-forward + helpers"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/secmix-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT

# Wait up to ~15s for the port-forward to accept connections.
# Use /dev/tcp (bash builtin) — fast, no HTTP traffic the policy
# might reject (the curl probe used to swallow the 401 and we got
# false-positive readiness). Also bail early if the pf process died.
pf_ready=""
for _ in $(seq 1 30); do
  if (echo > /dev/tcp/localhost/${LOCAL_PORT}) 2>/dev/null; then
    pf_ready=1
    break
  fi
  if ! kill -0 ${PF} 2>/dev/null; then break; fi
  sleep 0.5
done

if [[ -z "${pf_ready}" ]]; then
  printf '\n\033[1;31m✗\033[0m port-forward never came up on localhost:%s\n' "${LOCAL_PORT}" >&2
  echo "  kubectl port-forward log (/tmp/secmix-pf.log):" >&2
  sed 's/^/    /' /tmp/secmix-pf.log >&2 || true
  echo "  Likely causes:" >&2
  echo "    1. Data plane pod isn't Running (kind out of resources)." >&2
  echo "       kubectl -n envoy-gateway-system get pods -l \\" >&2
  echo "         gateway.envoyproxy.io/owning-gateway-name=${GATEWAY}" >&2
  echo "    2. Another process holds :${LOCAL_PORT}." >&2
  echo "       lsof -i :${LOCAL_PORT}  (and pkill any stale 'kubectl port-forward')" >&2
  exit 1
fi
ok "port-forward live on localhost:${LOCAL_PORT}"

URL="http://localhost:${LOCAL_PORT}/"

# alice/password basic-auth header value.
ALICE='Authorization: Basic YWxpY2U6cGFzc3dvcmQ='

# Helper: expect a specific HTTP code.
check() {
  local label="$1" expected_code="$2"
  shift 2
  local code
  code=$(curl -sS -o /tmp/secmix-body --max-time 5 -w '%{http_code}' "$@" "${URL}" || echo "ERR")
  if [[ "${code}" == "${expected_code}" ]]; then
    ok "${label}: HTTP ${code} (expected)"
  else
    warn "${label}: HTTP ${code} (expected ${expected_code})"
    echo "      body: $(head -1 /tmp/secmix-body 2>/dev/null | cut -c1-160)"
  fi
}

# ----------------------------------------------------------------------- #
hr "3. basicAuth — no credentials -> 401"

# A trusted XFF so we don't trip the IP allowlist while testing auth.
check "no Authorization header" 401 -H "X-Forwarded-For: 10.0.0.5"

# ----------------------------------------------------------------------- #
hr "4. basicAuth — wrong password -> 401"

WRONG='Authorization: Basic YWxpY2U6d3Jvbmc='   # alice:wrong
check "wrong password" 401 -H "X-Forwarded-For: 10.0.0.5" -H "${WRONG}"

# ----------------------------------------------------------------------- #
hr "5. basicAuth + IP allow — correct creds + allowed XFF -> 200"

check "alice/password + allowed IP" 200 \
  -H "X-Forwarded-For: 10.0.0.5" -H "${ALICE}"

# Show what the backend sees — proves the basic-auth header survived.
note "Backend's view of the auth header (passed through by default):"
curl -sS -H "X-Forwarded-For: 10.0.0.5" -H "${ALICE}" \
  "http://localhost:${LOCAL_PORT}/echo" \
  | jq '{authorization: .headers.Authorization, xff: .headers["X-Forwarded-For"]}' \
  | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "6. authorization — correct creds but DENIED IP -> 403"

# 8.8.8.8 is outside any allowed CIDR.
check "alice/password + denied IP" 403 \
  -H "X-Forwarded-For: 8.8.8.8" -H "${ALICE}"

# ----------------------------------------------------------------------- #
hr "7. CORS preflight — allowed origin"

note "OPTIONS request from https://app.example.com (allowed)"
out=$(curl -sS -i --max-time 5 \
  -X OPTIONS \
  -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: authorization, content-type" \
  "${URL}" 2>/dev/null || true)
echo "${out}" | awk 'BEGIN{IGNORECASE=1} /^HTTP|^access-control-/{print "    " $0}' | tr -d '\r' | head -10
echo "${out}" | grep -qi 'access-control-allow-origin: https://app.example.com' \
  && ok "preflight got CORS headers for app.example.com" \
  || warn "no CORS headers for allowed origin — check SecurityPolicy.cors.allowOrigins"

# ----------------------------------------------------------------------- #
hr "8. CORS preflight — denied origin"

note "OPTIONS request from https://evil.example.com (NOT in allowOrigins)"
out=$(curl -sS -i --max-time 5 \
  -X OPTIONS \
  -H "Origin: https://evil.example.com" \
  -H "Access-Control-Request-Method: POST" \
  "${URL}" 2>/dev/null || true)
echo "${out}" | awk 'BEGIN{IGNORECASE=1} /^HTTP|^access-control-/{print "    " $0}' | tr -d '\r' | head -10
if echo "${out}" | grep -qi 'access-control-allow-origin: https://evil.example.com'; then
  warn "Envoy echoed back the disallowed origin — investigate"
else
  ok "denied origin got NO Access-Control-Allow-Origin (browser would block)"
fi

# ----------------------------------------------------------------------- #
hr "9. Mapping — relevant HCM filters"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/secmix-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "Envoy HTTP filters in order:"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | (.filter_chains // [])[]
    | (.filters // [])[]
    | select(.name == "envoy.filters.network.http_connection_manager")
    | (.typed_config.http_filters // [])[]
    | .name] | unique' | sed 's/^/    /'

note "Look for: envoy.filters.http.cors, envoy.filters.http.rbac"
note "(IP allow/deny), envoy.filters.http.basic_auth."

cat <<'EOF' | sed 's/^/    /'

SecurityPolicy sub-feature      Envoy filter
------------------------------- -------------------------------------
cors                            envoy.filters.http.cors
authorization (CIDR rules)      envoy.filters.http.rbac (network /
                                  HTTP RBAC depending on principal type)
basicAuth                       envoy.filters.http.basic_auth

Filter order in the HCM chain (per Envoy + EG):
  cors -> [oauth2/jwt for ex 13/14] -> rbac -> basic_auth -> router

So CORS preflight short-circuits BEFORE auth — that's why a
disallowed origin's OPTIONS doesn't need credentials, and a valid
origin's OPTIONS responds 200 even without an Authorization header.
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  curl -u alice:password -H 'X-Forwarded-For: 10.0.0.5' http://localhost:${LOCAL_PORT}/echo"
echo "  curl -X OPTIONS -H 'Origin: https://app.example.com' \\\\"
echo "       -H 'Access-Control-Request-Method: POST' -i http://localhost:${LOCAL_PORT}/"
