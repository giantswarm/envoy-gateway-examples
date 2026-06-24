#!/usr/bin/env bash
#
# Behavioral tests for retry + timeout (using helloworld's /fail and
# /slow endpoints), config-dump proof for LB, active HC, and outlier
# detection.

set -euo pipefail

NS=demo
GATEWAY=tuned-backend
LOCAL_PORT=18130
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

btp_acc=$(kubectl -n "${NS}" get backendtrafficpolicy tuned-backend-policy \
  -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
[[ "${btp_acc}" == "True" ]] && ok "BackendTrafficPolicy Accepted=True" \
                              || warn "BackendTrafficPolicy Accepted=${btp_acc:-<none>}"

# ----------------------------------------------------------------------- #
hr "2. Port-forward + baseline"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/btrp-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 "http://localhost:${LOCAL_PORT}/" 2>/dev/null && break
  sleep 0.5
done

note "Baseline GET / — expect 200 from one of the 3 helloworld replicas"
curl -sS "http://localhost:${LOCAL_PORT}/" | jq '{msg, from_}' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "3. Feature: retry (numRetries=3, retryOn 503)"

note "Hit /fail?code=503 — helloworld always returns 503 here."
note "Envoy will retry 3 times, all fail, client gets the final 503."
note "Look at the Envoy access log to confirm Envoy made multiple attempts."

# Snapshot log line-count before, then hit /fail and diff.
POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
before=$(kubectl -n "${EG_NS}" logs "${POD}" -c envoy 2>/dev/null | wc -l | tr -d ' ')

t0=$(date +%s)
code=$(curl -sS -o /dev/null -w '%{http_code}\n' "http://localhost:${LOCAL_PORT}/fail?code=503")
t1=$(date +%s)
echo "    final response: HTTP ${code} (after $((t1 - t0))s)"

note "New access-log entries since the request started (each retry = 1 line):"
sleep 1   # let Envoy flush
kubectl -n "${EG_NS}" logs "${POD}" -c envoy 2>/dev/null \
  | tail -n +$((before + 1)) \
  | grep -E '/fail\?code=503|"GET /fail' \
  | sed 's/^/    /' || true

note "Also look at x-envoy-attempt-count on a response:"
# /headers echoes Envoy's internal headers. Just hit / once to retrieve them.
curl -sS -i "http://localhost:${LOCAL_PORT}/" \
  | awk 'BEGIN{IGNORECASE=1} /^x-envoy/{print "    " $0}' | tr -d '\r' || true

# ----------------------------------------------------------------------- #
hr "4. Feature: timeout.http.requestTimeout=2s"

note "Hit /slow?seconds=5 — helloworld will sleep 5s before responding."
note "Envoy's policy is 2s, so the client gets 504 Gateway Timeout at ~2s."

t0=$(date +%s)
code=$(curl -sS -o /tmp/btrp-body --max-time 10 -w '%{http_code}\n' \
  "http://localhost:${LOCAL_PORT}/slow?seconds=5")
t1=$(date +%s)
elapsed=$((t1 - t0))
echo "    HTTP ${code} after ${elapsed}s"
echo "    body first line: $(head -1 /tmp/btrp-body 2>/dev/null | cut -c1-120)"

if [[ "${code}" == "504" || "${code}" == "408" ]] && [[ "${elapsed}" -le 4 ]]; then
  ok "request timeout fired around 2s (got ${code} after ${elapsed}s)"
else
  warn "expected 504/408 within ~3s; got ${code} after ${elapsed}s"
fi

# ----------------------------------------------------------------------- #
hr "5. /config_dump — where each BTP field landed"

kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/btrp-admin.log 2>&1 &
ADMIN_PF=$!
trap 'kill -TERM ${PF} ${ADMIN_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null && break
  sleep 0.5
done

DUMP=$(curl -sS http://localhost:19000/config_dump 2>/dev/null || echo "{}")

note "Cluster-level: lb_policy, outlier_detection, health_checks, circuit_breakers"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("ClustersConfigDump"))
    | (.dynamic_active_clusters // [])[]
    | .cluster
    | select(.name | tostring | test("helloworld"))
    | { name,
        lb_policy: .lb_policy,
        outlier_detection: (.outlier_detection // null) | {
          consecutive_5xx,
          base_ejection_time,
          max_ejection_percent
        },
        health_checks: [(.health_checks // [])[] | {
          timeout, interval, unhealthy_threshold, healthy_threshold,
          path: .http_health_check.path
        }],
        circuit_breakers_present: (.circuit_breakers != null)
      }]' | sed 's/^/    /'

note "Route-level: retry_policy + timeout"
echo "${DUMP}" | jq '[.configs[]?
    | select(."@type"|endswith("RoutesConfigDump"))
    | ((.dynamic_route_configs // []) + (.static_route_configs // []))[]
    | .route_config
    | (.virtual_hosts // [])[]
    | (.routes // [])[]
    | { match_path: (.match.path // .match.prefix),
        timeout: .route.timeout,
        retry_policy: (.route.retry_policy // null) | {
          retry_on,
          num_retries,
          per_try_timeout,
          retriable_status_codes
        }
      }] | .[0:3]' | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "6. Mapping — BTP fields to Envoy artifacts"

cat <<'EOF' | sed 's/^/    /'
BTP field                                    Envoy artifact
-------------------------------------------- ----------------------------------
retry.numRetries / .retryOn / .perRetry     route_config.routes[].route
                                              .retry_policy
timeout.http.requestTimeout                  route_config.routes[].route.timeout
timeout.tcp.connectTimeout                   cluster.connect_timeout
loadBalancer.type                            cluster.lb_policy
loadBalancer.consistentHash.{type,header}    cluster.lb_subset_config /
                                              ring_hash_lb_config
healthCheck.active                           cluster.health_checks[]
healthCheck.passive (outlier)                cluster.outlier_detection
circuitBreaker.maxConnections etc.           cluster.circuit_breakers
proxyProtocol.version                        cluster.transport_socket... (wraps)
faultInjection.delay / .abort                route's typed_per_filter_config
                                              (envoy.filters.http.fault)
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make admin                          # Envoy admin endpoint"
echo "  curl http://localhost:${LOCAL_PORT}/fail?code=500    # NOT in retryOn list -> no retry"
echo "  curl http://localhost:${LOCAL_PORT}/fail?code=503    # WILL be retried"
echo "  curl http://localhost:${LOCAL_PORT}/slow?seconds=1   # under 2s, succeeds"
echo "  kubectl -n ${NS} describe backendtrafficpolicy tuned-backend-policy"
