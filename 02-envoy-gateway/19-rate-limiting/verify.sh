#!/usr/bin/env bash
#
# Hammers each rate-limit bucket and asserts the cutoff fires at
# the right request number.
#
# Buckets:
#   x-tenant: free      ->   5 / minute
#   x-tenant: premium   -> 100 / minute
#   (no header)         ->  10 / minute  (catch-all)

set -euo pipefail

NS=demo
GATEWAY=ratelimit-gateway
LOCAL_PORT=18190
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

btp_acc=$(kubectl -n "${NS}" get backendtrafficpolicy ratelimit \
  -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
[[ "${btp_acc}" == "True" ]] && ok "BackendTrafficPolicy Accepted=True" \
                              || warn "BackendTrafficPolicy Accepted=${btp_acc:-<none>}"

# ----------------------------------------------------------------------- #
hr "2. Port-forward"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/rl-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT

pf_ready=""
for _ in $(seq 1 30); do
  if (echo > /dev/tcp/localhost/${LOCAL_PORT}) 2>/dev/null; then pf_ready=1; break; fi
  if ! kill -0 ${PF} 2>/dev/null; then break; fi
  sleep 0.5
done
[[ -n "${pf_ready}" ]] || fail "port-forward never came up (see /tmp/rl-pf.log)"
ok "port-forward live on localhost:${LOCAL_PORT}"

URL="http://localhost:${LOCAL_PORT}/"

# Send N requests with optional header, print the count of each code.
# Usage: hammer N "tenant-name" "x-tenant: free"     (header optional)
hammer() {
  local n=$1
  local label="$2"
  shift 2
  local codes=()
  for _ in $(seq 1 "$n"); do
    c=$(curl -sS -o /dev/null --max-time 3 -w '%{http_code}' "$@" "${URL}" || echo "ERR")
    codes+=("$c")
  done
  # Build a "code -> count" summary.
  local summary
  summary=$(printf '%s\n' "${codes[@]}" | sort | uniq -c | awk '{printf "%s=%d ", $2, $1}')
  printf '   %-22s -> %s\n' "${label}" "${summary}"
  # Echo for caller's grep.
  printf '%s\n' "${codes[@]}"
}

# ----------------------------------------------------------------------- #
hr "3. free tenant (limit=5/min) — burst of 8 requests"

note "Expect first 5 -> 200, requests 6-8 -> 429."
out=$(hammer 8 "free (5/min)" -H "x-tenant: free")
n_200=$(echo "${out}" | grep -c '^200$' || true)
n_429=$(echo "${out}" | grep -c '^429$' || true)
[[ "${n_200}" == "5" && "${n_429}" == "3" ]] \
  && ok "free bucket cutoff at 5 (got 5 x 200 + 3 x 429)" \
  || warn "expected 5/3, got ${n_200} x 200 + ${n_429} x 429"

# ----------------------------------------------------------------------- #
hr "4. premium tenant (limit=100/min) — burst of 8 requests"

note "Expect all 8 -> 200 (well under the 100/min cap)."
out=$(hammer 8 "premium (100/min)" -H "x-tenant: premium")
n_200=$(echo "${out}" | grep -c '^200$' || true)
[[ "${n_200}" == "8" ]] && ok "all 8 premium requests passed" \
                        || warn "expected 8/8 200; got ${n_200}"

# ----------------------------------------------------------------------- #
hr "5. catch-all (limit=10/min) — burst of 13 requests, no x-tenant"

note "Expect first 10 -> 200, requests 11-13 -> 429."
out=$(hammer 13 "catch-all (10/min)")
n_200=$(echo "${out}" | grep -c '^200$' || true)
n_429=$(echo "${out}" | grep -c '^429$' || true)
[[ "${n_200}" == "10" && "${n_429}" == "3" ]] \
  && ok "catch-all cutoff at 10 (got 10 x 200 + 3 x 429)" \
  || warn "expected 10/3, got ${n_200} x 200 + ${n_429} x 429"

# ----------------------------------------------------------------------- #
hr "6. Inspect a 429 response — body + headers"

curl -sS -i --max-time 3 -H "x-tenant: free" "${URL}" \
  | head -10 | sed 's/^/    /' || true

# ----------------------------------------------------------------------- #
hr "7. Mapping — /config_dump shows the local_ratelimit filter"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/rl-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "HCM http_filters — look for envoy.filters.http.local_ratelimit"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ListenersConfigDump"))
    | (.dynamic_listeners // [])[]
    | .active_state.listener
    | (.filter_chains // [])[]
    | (.filters // [])[]
    | select(.name == "envoy.filters.network.http_connection_manager")
    | (.typed_config.http_filters // [])[]
    | .name] | unique' | sed 's/^/    /'

note "Route-level rate-limit descriptors (where the per-tenant"
note "rules attach as typed_per_filter_config):"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | ((.dynamic_route_configs // []) + (.static_route_configs // []))[]
    | .route_config
    | (.virtual_hosts // [])[]
    | (.routes // [])[]
    | { match_path: (.match.path // .match.prefix),
        has_per_route_local_ratelimit: (
          (.typed_per_filter_config // {})
          | has("envoy.filters.http.local_ratelimit")
        )
      }] | .[0:5]' | sed 's/^/    /'

cat <<'EOF' | sed 's/^/    /'

BTP.rateLimit field             Envoy artifact
------------------------------- ------------------------------------------------
type: Local                     envoy.filters.http.local_ratelimit filter
                                  attached at the route/typed_per_filter_config
                                  level
local.rules[].clientSelectors   descriptors / header matchers per route
local.rules[].limit             token_bucket { max_tokens, fill_interval }
local.body                      response_body for the rejected request

type: Global                    envoy.filters.http.ratelimit filter (different
                                  filter!) pointing at EG's external ratelimit
                                  service. Requires the `rateLimit` block in
                                  the EnvoyGateway controller config plus a
                                  Redis-backed ratelimit Deployment.
EOF

hr "Done."
echo "Wait 60s and retry — the buckets refill per minute."
echo "Useful follow-ups:"
echo "  for i in \$(seq 1 8); do curl -o /dev/null -w '%{http_code} ' \\\\"
echo "    -H 'x-tenant: free' http://localhost:${LOCAL_PORT}/ ; done ; echo"
echo "  kubectl -n ${NS} describe backendtrafficpolicy ratelimit"
