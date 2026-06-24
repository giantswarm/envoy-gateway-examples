#!/usr/bin/env bash
#
# Exercises five JWT scenarios against the SecurityPolicy:
#   missing / valid / expired / wrong audience / wrong issuer
# Then dumps the jwt_authn filter from /config_dump.

set -euo pipefail

NS=demo
GATEWAY=jwt-gateway
LOCAL_PORT=18140
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
sub()   { printf '\n\033[1;36m-- %s --\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
fail()  { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f keys/private.pem ]] || fail "keys/ missing — run 'make up' first"

# ----------------------------------------------------------------------- #
hr "1. Resource status"

gw_prog=$(kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${gw_prog}" == "True" ]] && ok "Gateway/${GATEWAY} Programmed=True" \
                              || fail "Gateway not Programmed (got '${gw_prog:-<none>}')"

sp_acc=$(kubectl -n "${NS}" get securitypolicy jwt-protect \
  -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
[[ "${sp_acc}" == "True" ]] && ok "SecurityPolicy Accepted=True" \
                              || warn "SecurityPolicy Accepted=${sp_acc:-<none>} — see 'make logs'"

# ----------------------------------------------------------------------- #
hr "2. Port-forward the data plane"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/jwt-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sS -o /dev/null --max-time 1 "http://localhost:${LOCAL_PORT}/" 2>/dev/null && break
  sleep 0.5
done

URL="http://localhost:${LOCAL_PORT}/echo"

# Pass extra curl args as positional params so quoting survives:
#   check "label" 200 -H "Authorization: Bearer ${token}"
# Trying to pass them as a single quoted string breaks because the
# inner quotes are literal — curl would word-split and treat 'Bearer'
# as a URL ("Could not resolve host: Bearer").
check() {
  local label="$1" expected_code="$2"
  shift 2
  local code
  code=$(curl -sS -o /tmp/jwt-body --max-time 5 -w '%{http_code}' \
    "$@" "${URL}" || echo "ERR")
  if [[ "${code}" == "${expected_code}" ]]; then
    ok "${label}: HTTP ${code} (expected)"
  else
    warn "${label}: HTTP ${code} (expected ${expected_code})"
    echo "      body: $(head -1 /tmp/jwt-body 2>/dev/null | cut -c1-160)"
  fi
}

# ----------------------------------------------------------------------- #
hr "3. No token -> 401"

check "no Authorization header" 401

# ----------------------------------------------------------------------- #
hr "4. Valid token -> 200 + claims appear on backend headers"

token=$(./mint-token.sh)
note "Token issued for sub=alice, aud=api.local."

check "valid token" 200 -H "Authorization: Bearer ${token}"

note "Inspect the backend's view of the headers (should include x-user/x-aud):"
curl -sS -H "Authorization: Bearer ${token}" "${URL}" \
  | jq '{from_, x_user: .headers["X-User"], x_aud: .headers["X-Aud"]}' \
  | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "5. Expired token -> 401"

exp_token=$(EXP=100 ./mint-token.sh)         # exp = 1970-ish
note "Token exp=100 (1970). Should be rejected as expired."
check "expired token" 401 -H "Authorization: Bearer ${exp_token}"

# ----------------------------------------------------------------------- #
hr "6. Wrong audience -> 401"

other_aud=$(AUD=other-service ./mint-token.sh)
note "Token aud=other-service. Policy only accepts aud=api.local."
check "wrong aud" 401 -H "Authorization: Bearer ${other_aud}"

# ----------------------------------------------------------------------- #
hr "7. Wrong issuer -> 401"

other_iss=$(ISS=https://bad-issuer.example.com ./mint-token.sh)
note "Token iss=https://bad-issuer.example.com. Policy expects https://tutorial-issuer.example.com."
check "wrong iss" 401 -H "Authorization: Bearer ${other_iss}"

# ----------------------------------------------------------------------- #
hr "8. Mapping — jwt_authn filter in /config_dump"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/jwt-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "HCM http_filters list — look for envoy.filters.http.jwt_authn"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | (.filter_chains // [])[]
    | (.filters // [])[]
    | select(.name == "envoy.filters.network.http_connection_manager")
    | .typed_config.http_filters // []
    | .[]
    | { name, disabled: .disabled }]' | sed 's/^/    /'

note "jwt_authn provider config (truncated):"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | (.filter_chains // [])[]
    | (.filters // [])[]
    | select(.name == "envoy.filters.network.http_connection_manager")
    | (.typed_config.http_filters // [])[]
    | select(.name | tostring | test("jwt_authn"))
    | .typed_config
    | { providers: (.providers // {} | to_entries | map(.key + ": iss=" + .value.issuer + " auds=" + (.value.audiences|tostring))),
        rules: ((.rules // []) | length)
      }]' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "9. Mapping — SecurityPolicy.jwt fields to Envoy artifacts"

cat <<'EOF' | sed 's/^/    /'
SecurityPolicy.jwt field                        Envoy artifact
----------------------------------------------- -------------------------------------
providers[].issuer                              jwt_authn.providers[].issuer
providers[].audiences[]                         jwt_authn.providers[].audiences[]
providers[].localJWKS.inline                    jwt_authn.providers[].local_jwks
                                                  .inline_string
providers[].remoteJWKS.uri                      jwt_authn.providers[].remote_jwks
                                                  .http_uri.uri
providers[].claimToHeaders[].claim/header       jwt_authn.providers[].claim_to_headers
providers[].recomputeRoute                      (re-runs HCM route table after extract)
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  ./mint-token.sh                                   # mint a default valid token"
echo "  EXP=\$(date -v +1H +%s) ./mint-token.sh            # 1-hour expiry"
echo "  SUB=bob EXTRA='{\"role\":\"admin\"}' ./mint-token.sh   # add claims"
echo "  kubectl -n ${NS} describe securitypolicy jwt-protect"
