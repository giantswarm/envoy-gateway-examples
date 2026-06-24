#!/usr/bin/env bash
#
# Confirms the OIDC SecurityPolicy is wired up correctly:
#   - SecurityPolicy Accepted
#   - Unauthenticated request -> 302 to Dex /auth
#   - oauth2 filter present in /config_dump
#
# The full browser-driven login dance is documented in README and
# left as a manual step (curl-driven OIDC is brittle: CSRF tokens,
# HTML form parsing, cookie handling, etc).

set -euo pipefail

NS=demo
GATEWAY=oidc-gateway
APP_PORT=18150
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
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

sp_acc=$(kubectl -n "${NS}" get securitypolicy oidc-protect \
  -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
[[ "${sp_acc}" == "True" ]] && ok "SecurityPolicy Accepted=True" \
                              || warn "SecurityPolicy Accepted=${sp_acc:-<none>} — see 'make logs'"

# Dex up?
dex_ready=$(kubectl -n "${NS}" get deploy dex \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[[ "${dex_ready}" == "1" ]] && ok "Dex Deployment ready" \
                             || warn "Dex Deployment not ready (readyReplicas=${dex_ready})"

# ----------------------------------------------------------------------- #
hr "2. Port-forward the data plane (:${APP_PORT} -> svc :80)"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${APP_PORT}:80" \
  >/tmp/oidc-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sS -o /dev/null --max-time 1 \
    --resolve "app.local:${APP_PORT}:127.0.0.1" \
    "http://app.local:${APP_PORT}/" 2>/dev/null && break
  sleep 0.5
done

# ----------------------------------------------------------------------- #
hr "3. Unauthenticated request -> expect 302 redirect to Dex /auth"

response=$(curl -sS -i --max-time 5 \
  --resolve "app.local:${APP_PORT}:127.0.0.1" \
  "http://app.local:${APP_PORT}/" 2>/dev/null || true)

# Print first 8 lines (status + key headers).
echo "${response}" | head -8 | sed 's/^/    /'

status_line=$(echo "${response}" | head -1 | tr -d '\r')
location=$(echo "${response}" | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r')

if echo "${status_line}" | grep -qE 'HTTP/.* 302'; then
  ok "got 302 redirect"
else
  warn "expected 302, got: ${status_line}"
fi

if echo "${location}" | grep -q '/dex/auth'; then
  ok "Location header points at Dex /auth: ${location:0:120}..."
else
  warn "expected Location to /dex/auth; got: ${location}"
fi

# Pull out the OIDC params to prove EG passed sensible values.
note "Parameters Envoy added to the redirect URL:"
echo "${location}" | tr '&' '\n' | grep -E '^https?|^[a-z_]+=' | head -10 | sed 's/^/    /' || true

# ----------------------------------------------------------------------- #
hr "4. /config_dump — oauth2 filter present in the HCM chain"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/oidc-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "HCM http_filters — look for envoy.filters.http.oauth2"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | (.filter_chains // [])[]
    | (.filters // [])[]
    | select(.name == "envoy.filters.network.http_connection_manager")
    | (.typed_config.http_filters // [])[]
    | { name, disabled: (.disabled // false) }]' | sed 's/^/    /'

note "oauth2 config — token / authorization endpoints and the redirect"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | (.filter_chains // [])[]
    | (.filters // [])[]
    | select(.name == "envoy.filters.network.http_connection_manager")
    | (.typed_config.http_filters // [])[]
    | select(.name | tostring | test("oauth2"))
    | .typed_config.config
    | { token_endpoint: .token_endpoint,
        authorization_endpoint: .authorization_endpoint,
        redirect_uri: .redirect_uri,
        signout_path: .signout_path,
        forward_bearer_token: .forward_bearer_token,
        auth_scopes: .auth_scopes
      }]' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "5. Doing the full login flow MANUALLY in a real browser"

cat <<EOF | sed 's/^/    /'
The end-to-end OIDC flow needs a browser (curl can do it but the
CSRF + cookie + HTML-form dance is too brittle for a tutorial).

In ONE terminal, port-forward the Gateway:

    make pf

In a SECOND terminal, port-forward Dex (so your browser can reach
its login page):

    make pf-dex

Add to /etc/hosts (or use a browser extension):

    127.0.0.1   app.local
    127.0.0.1   dex.local

Then open in your browser:

    http://app.local:${APP_PORT}/

You should see:
    1. Browser is redirected to http://dex.local:18151/dex/auth?...
    2. Dex shows its login form. Use:
         email:    admin@example.com
         password: password
    3. After submit, redirect back to app.local:${APP_PORT}/oauth2/callback
       with ?code=...
    4. EG/Envoy exchanges the code, sets a session cookie, redirects
       you to / .
    5. helloworld JSON appears — proof you're logged in.

To log out:

    curl -L --cookie-jar /tmp/jar -b /tmp/jar \\
      --resolve app.local:${APP_PORT}:127.0.0.1 \\
      "http://app.local:${APP_PORT}/logout"
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make pf           # port-forward Gateway"
echo "  make pf-dex       # port-forward Dex"
echo "  make admin        # port-forward Envoy admin"
echo "  kubectl -n ${NS} describe securitypolicy oidc-protect"
echo "  kubectl -n ${NS} logs -l app=dex --tail=50"
