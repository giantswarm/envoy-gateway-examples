#!/usr/bin/env bash
#
# Exercises three observable ClientTrafficPolicy features by hitting
# helloworld's /echo (which returns the headers + path as the backend
# saw them).

set -euo pipefail

NS=demo
GATEWAY=tuned-client
LOCAL_PORT=18120
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

ctp_acc=$(kubectl -n "${NS}" get clienttrafficpolicy tuned-client-policy \
  -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
[[ "${ctp_acc}" == "True" ]] && ok "ClientTrafficPolicy Accepted=True" \
                              || warn "ClientTrafficPolicy Accepted=${ctp_acc:-<none>} — see 'make logs'"

# ----------------------------------------------------------------------- #
hr "2. Port-forward and a baseline request"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/ctp-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 "http://localhost:${LOCAL_PORT}/" 2>/dev/null && break
  sleep 0.5
done

note "Plain GET /echo — sanity check:"
curl -sS "http://localhost:${LOCAL_PORT}/echo" \
  | jq '{method, path, from_}' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "3. Feature: clientIPDetection.xForwardedFor.numTrustedHops"

note "Send X-Forwarded-For: 203.0.113.42, 198.51.100.7"
note "With numTrustedHops=1, Envoy trusts the LAST hop of that XFF and"
note "treats 198.51.100.7 as the real client. The backend's view:"

xff=$(curl -sS \
  -H "X-Forwarded-For: 203.0.113.42, 198.51.100.7" \
  "http://localhost:${LOCAL_PORT}/echo" \
  | jq -r '.headers["X-Forwarded-For"] // empty')
echo "    backend saw X-Forwarded-For: ${xff}"

if echo "${xff}" | grep -q "198.51.100.7"; then
  ok "real-client IP propagated to upstream"
else
  warn "X-Forwarded-For didn't make it through as expected"
fi

# ----------------------------------------------------------------------- #
hr "4. Feature: http1.preserveHeaderCase"

note "Send a mixed-case custom header. With preserveHeaderCase=true the"
note "backend sees the SAME casing; without it (the default) the header"
note "would arrive as 'x-tutorial-tag'."

curl -sS -H "X-Tutorial-Tag: PreservedCase" "http://localhost:${LOCAL_PORT}/echo" \
  | jq '{headers_x_tutorial: .headers["X-Tutorial-Tag"], headers_lower: .headers["x-tutorial-tag"]}' \
  | sed 's/^/    /'

note "Flask normalizes header keys for lookup, so both keys may resolve."
note "Look at the raw header listing instead to confirm wire-level case:"
curl -sS -D - -o /dev/null "http://localhost:${LOCAL_PORT}/echo" \
  | awk '/^[Ss]erver|^[Xx]-[Ee]nvoy|^[Cc]ontent-/{print "    " $0}' | tr -d '\r' | head -8

# ----------------------------------------------------------------------- #
hr "5. Feature: path.disableMergeSlashes"

note "Hit /echo//double — by default Envoy would merge to /echo/double"
note "BEFORE forwarding. With disableMergeSlashes=true Envoy forwards"
note "the path verbatim — but the backend's URL parser may still 404"
note "if it doesn't have a literal /echo//double route (Flask doesn't)."
note "So we check the AUTHORITATIVE source: Envoy's access log."

# Print the response code + first line of body (likely a 404 HTML page
# from Flask since /echo//double isn't a registered route).
body=$(curl -sS -o /tmp/ctp-body -w '%{http_code}' \
  "http://localhost:${LOCAL_PORT}/echo//double" 2>/dev/null || true)
echo "    HTTP ${body}"
echo "    body (first line): $(head -1 /tmp/ctp-body 2>/dev/null | sed 's/^/      /' | cut -c1-120)"

# The proof that disableMergeSlashes worked: Envoy's access log
# records the path AS IT FORWARDED IT. EG enables stdout access logs
# by default.
POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
note "Envoy access log line(s) for that request:"
kubectl -n "${EG_NS}" logs "${POD}" -c envoy --tail=50 2>/dev/null \
  | grep -E 'GET /echo' | tail -3 | sed 's/^/    /' || true
note "If the path in the log reads '/echo//double', merge_slashes is OFF"
note "(policy is taking effect). If it reads '/echo/double', the policy"
note "didn't apply yet — wait a few seconds and re-run verify."

# ----------------------------------------------------------------------- #
hr "6. Mapping — where each CTP field lands in /config_dump"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/ctp-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "HCM-level settings on the listener — relevant fields:"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | (.filter_chains // [])[]
    | (.filters // [])[]
    | select(.name == "envoy.filters.network.http_connection_manager")
    | .typed_config
    | { xff_num_trusted_hops:           .xff_num_trusted_hops,
        use_remote_address:             .use_remote_address,
        http_protocol_options:          .http_protocol_options,
        merge_slashes:                  .merge_slashes,
        normalize_path:                 .normalize_path
      }]' | sed 's/^/    /'

cat <<'EOF' | sed 's/^/    /'

How CTP fields appear in the generated Envoy config:

  CTP field                                    Envoy HCM/listener field
  ------------------------------------------- ----------------------------------
  clientIPDetection.xForwardedFor              xff_num_trusted_hops
    .numTrustedHops
                                               use_remote_address (controls
                                                 whether Envoy appends its own
                                                 source IP to XFF)

  http1.preserveHeaderCase                     http_protocol_options
                                                 .header_key_format
                                                 .stateful_formatter
                                                 (preserve_case_formatter)

  path.disableMergeSlashes                     merge_slashes (inverted: false
                                                 when the CTP field is true)
  path.escapedSlashesAction                    path_with_escaped_slashes_action
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make admin                          # Envoy admin endpoint"
echo "  kubectl -n ${NS} describe clienttrafficpolicy tuned-client-policy"
echo "  kubectl -n ${NS} get clienttrafficpolicy tuned-client-policy -o yaml | yq .status"
