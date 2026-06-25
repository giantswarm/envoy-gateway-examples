#!/usr/bin/env bash
#
# Drives both HTTPRouteFilters:
#   1. /users/<id> -> capture-group rewrite -> /echo?user_id=<id>
#   2. /healthz    -> directResponse, no backend call
# Plus a catch-all sanity check.

set -euo pipefail

NS=demo
GATEWAY=route-filter
LOCAL_PORT=18200
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

rt_refs=$(kubectl -n "${NS}" get httproute route-filter \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)
[[ "${rt_refs}" == "True" ]] && ok "HTTPRoute ResolvedRefs=True (both filter CRs resolved)" \
                              || warn "HTTPRoute ResolvedRefs=${rt_refs:-<none>}"

# ----------------------------------------------------------------------- #
hr "2. Port-forward"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/hrf-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
pf_ready=""
for _ in $(seq 1 30); do
  if (echo > /dev/tcp/localhost/${LOCAL_PORT}) 2>/dev/null; then pf_ready=1; break; fi
  if ! kill -0 ${PF} 2>/dev/null; then break; fi
  sleep 0.5
done
[[ -n "${pf_ready}" ]] || fail "port-forward never came up (see /tmp/hrf-pf.log)"
ok "port-forward live on localhost:${LOCAL_PORT}"

# ----------------------------------------------------------------------- #
hr "3. Capture-group rewrite: /users/42 -> /echo?user_id=42"

note "Backend should see path=/echo AND args.user_id=42."
curl -sS --max-time 5 "http://localhost:${LOCAL_PORT}/users/42" \
  | jq '{from_, path, args}' | sed 's/^/    /'

# Strict check.
got=$(curl -sS --max-time 5 "http://localhost:${LOCAL_PORT}/users/777" \
  | jq -r '.args.user_id // empty')
if [[ "${got}" == "777" ]]; then
  ok "capture group propagated as ?user_id=777"
else
  warn "expected user_id=777, got '${got}'"
fi

# ----------------------------------------------------------------------- #
hr "4. Capture-group regex doesn't over-match"

note "/users/abc is NOT \\d+ — should fall through to catch-all."
note "(helloworld returns 404 for an unknown path, which is correct here.)"
code=$(curl -sS -o /dev/null --max-time 5 -w '%{http_code}' \
  "http://localhost:${LOCAL_PORT}/users/abc")
echo "    HTTP ${code}"
if [[ "${code}" == "404" ]]; then
  ok "regex match scoped correctly — non-numeric ID fell through"
else
  warn "expected 404 from helloworld's catch-all; got ${code}"
fi

# ----------------------------------------------------------------------- #
hr "5. directResponse: /healthz returns 200 + JSON from Envoy, no backend"

note "Status + body — should be exactly what's in filter-healthz.yaml:"
curl -sS -i --max-time 5 "http://localhost:${LOCAL_PORT}/healthz" \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP|^content-type|^content-length/ || /status/{print "    " $0}' \
  | tr -d '\r' | head -8
echo
curl -sS --max-time 5 "http://localhost:${LOCAL_PORT}/healthz" | jq . | sed 's/^/    /'

note "Confirm NO request reached helloworld for this path:"
note "(check helloworld logs — there should be no /healthz entries)"
# `grep -c` exits 1 when the count is 0 — that's correct behavior but
# kills the script under `set -o pipefail`. Capture in a subshell with
# `|| echo 0` so a zero count is success, not failure.
hits=$( (kubectl -n "${NS}" logs -l app=helloworld --tail=20 2>/dev/null \
         | grep -c '/healthz') 2>/dev/null || echo 0 )
echo "    /healthz hits in helloworld logs: ${hits}"
if [[ "${hits}" == "0" ]]; then
  ok "no backend call for /healthz — directResponse short-circuited"
else
  warn "expected 0 hits, found ${hits} — directResponse may not be firing"
fi

# ----------------------------------------------------------------------- #
hr "6. Catch-all still works for unrelated paths"

curl -sS "http://localhost:${LOCAL_PORT}/" | jq '{msg, from_}' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "7. Mapping — relevant Envoy artifacts"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/hrf-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "Routes with their action (regex_rewrite vs direct_response):"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | ((.dynamic_route_configs // []) + (.static_route_configs // []))[]
    | .route_config
    | (.virtual_hosts // [])[]
    | (.routes // [])[]
    | { match: (.match.path // .match.prefix // .match.safe_regex.regex),
        action: (
          if .direct_response != null then
            "direct_response status=" + (.direct_response.status|tostring)
          elif .route.regex_rewrite != null then
            "regex_rewrite \"" + .route.regex_rewrite.pattern.regex + "\" -> \"" + .route.regex_rewrite.substitution + "\""
          elif .route.cluster != null then
            "forward to " + .route.cluster
          else
            "other"
          end
        )
      }]' | sed 's/^/    /'

cat <<'EOF' | sed 's/^/    /'

HTTPRouteFilter field                     Envoy artifact
---------------------------------------- -----------------------------------------
spec.urlRewrite.path                      route.route.regex_rewrite
   .replaceRegexMatch.pattern               .pattern.regex
   .replaceRegexMatch.substitution          .substitution

spec.directResponse                       route.direct_response
   .statusCode                              .status
   .body.inline                             .body.inline_string
   .body.valueRef (ConfigMap)               .body.inline_string (from ConfigMap)
   .contentType                             added as route.response_headers_to_add
                                              entry "content-type: <value>"

Attached to a route via the standard
HTTPRoute.filters[].type: ExtensionRef
mechanism — same shape as any other
ExtensionRef-style filter.
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  curl -i http://localhost:${LOCAL_PORT}/users/123"
echo "  curl -i http://localhost:${LOCAL_PORT}/healthz"
echo "  kubectl -n ${NS} describe httproutefilter users-rewrite"
