#!/usr/bin/env bash
#
# Drives traffic and confirms all three observability pillars work:
#   1. Access logs in JSON appear on the envoy pod's stdout
#   2. Prometheus metrics increase by the request count
#   3. Trace spans show up in the OTel Collector's debug export

set -euo pipefail

NS=demo
GATEWAY=observed
LOCAL_PORT=18210
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

otel_ready=$(kubectl -n "${NS}" get deploy otel-collector \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[[ "${otel_ready}" == "1" ]] && ok "OTel Collector Ready" \
                              || fail "OTel Collector not ready (${otel_ready}/1)"

# ----------------------------------------------------------------------- #
hr "2. Port-forward + drive a small burst of traffic"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  -o jsonpath='{.items[0].metadata.name}')
ok "Envoy Service: ${EG_NS}/${SVC}"
ok "Envoy Pod:     ${EG_NS}/${POD}"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80" \
  >/tmp/obs-pf.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
pf_ready=""
for _ in $(seq 1 30); do
  if (echo > /dev/tcp/localhost/${LOCAL_PORT}) 2>/dev/null; then pf_ready=1; break; fi
  if ! kill -0 ${PF} 2>/dev/null; then break; fi
  sleep 0.5
done
[[ -n "${pf_ready}" ]] || fail "port-forward never came up (see /tmp/obs-pf.log)"

# Snapshot the envoy pod's existing log line count so we can diff.
before_lines=$(kubectl -n "${EG_NS}" logs "${POD}" -c envoy 2>/dev/null | wc -l | tr -d ' ')

# Mark this burst with a unique X-Request-Id prefix so we can grep it.
TAG="verify-$(date +%s)"
note "Sending 5 requests tagged with x-request-id prefix '${TAG}'..."
for i in 1 2 3 4 5; do
  curl -sS -o /dev/null --max-time 5 \
    -H "x-request-id: ${TAG}-${i}" \
    "http://localhost:${LOCAL_PORT}/echo"
done
ok "5 requests sent"

# Give the OTel batch processor a moment to flush.
sleep 2

# ----------------------------------------------------------------------- #
hr "3. Access logs — JSON entries in envoy's stdout"

# Re-resolve POD because EG may have rolled the data plane after
# the EnvoyProxy change — the pod name in `$POD` from section 2
# may be the OLD terminating one.
POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY} \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
note "Reading logs from current pod: ${POD}"

sub "Last 5 access-log lines (filtered to our run):"
# All_logs goes in a variable so we don't double-shell-out.
all_logs=$(kubectl -n "${EG_NS}" logs "${POD}" -c envoy --tail=500 2>/dev/null || true)
matches=$(printf '%s\n' "${all_logs}" | grep -F "${TAG}" || true)

if [[ -n "${matches}" ]]; then
  printf '%s\n' "${matches}" | tail -5 \
    | jq -c '{start_time, method, path, status, duration_ms, request_id, upstream_cluster}' 2>/dev/null \
    | sed 's/^/    /' || {
        warn "lines found but jq parse failed — raw log:"
        printf '%s\n' "${matches}" | tail -3 | sed 's/^/      /'
      }
else
  warn "no log lines matched tag '${TAG}' — showing last 5 raw lines for diagnosis:"
  printf '%s\n' "${all_logs}" | tail -5 | sed 's/^/      /'
fi

# Count is just `wc -l` over the matches — never errors.
count=$(printf '%s' "${matches}" | grep -c "${TAG}" || true)
[[ -z "${count}" ]] && count=0
echo "    matching access-log lines for ${TAG}: ${count}"
if [[ "${count}" == "5" ]]; then
  ok "all 5 requests logged as JSON"
else
  warn "expected 5 log lines, found ${count}"
fi

# ----------------------------------------------------------------------- #
hr "4. Prometheus metrics — counter went up by 5"

# The Envoy data-plane image is distroless — no shell, no wget, no
# curl. Can't `kubectl exec` to fetch metrics. Port-forward the
# metrics port (19001) and curl from outside instead.
note "Port-forward :19001 (metrics) and pull /stats/prometheus:"
kubectl -n "${EG_NS}" port-forward "${POD}" 19001:19001 \
  >/tmp/obs-metrics-pf.log 2>&1 &
METRICS_PF=$!
trap 'kill -TERM ${PF} ${METRICS_PF} 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  if (echo > /dev/tcp/localhost/19001) 2>/dev/null; then break; fi
  if ! kill -0 ${METRICS_PF} 2>/dev/null; then break; fi
  sleep 0.5
done

metrics=$(curl -sS --max-time 5 http://localhost:19001/stats/prometheus 2>/dev/null \
  | grep -E '^envoy_http_downstream_rq_total' \
  | head -5 || true)
if [[ -n "${metrics}" ]]; then
  echo "${metrics}" | sed 's/^/    /'
  ok "Prometheus metrics endpoint reachable, envoy_http_downstream_rq_total emitted"
else
  warn "no envoy_http_downstream_rq_total metric found"
  warn "port-forward log:" ; sed 's/^/    /' /tmp/obs-metrics-pf.log || true
fi

kill -TERM ${METRICS_PF} 2>/dev/null || true
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT

# ----------------------------------------------------------------------- #
hr "5. Traces — OTel Collector printed spans"

OTEL_POD=$(kubectl -n "${NS}" get pods -l app=otel-collector \
  -o jsonpath='{.items[0].metadata.name}')
ok "OTel Collector pod: ${NS}/${OTEL_POD}"

note "Look for trace spans in the collector's debug output:"
trace_lines=$(kubectl -n "${NS}" logs "${OTEL_POD}" --tail=200 2>/dev/null \
  | grep -E 'Span|ResourceSpans|TraceId|user_agent.original|x-request-id' \
  | tail -15)
echo "${trace_lines}" | sed 's/^/    /' | head -25 || true

n_traceid=$( (kubectl -n "${NS}" logs "${OTEL_POD}" --tail=500 2>/dev/null \
              | grep -cE 'Trace ID|TraceId') 2>/dev/null || echo 0 )
echo "    trace IDs printed by collector: ${n_traceid}"
if [[ "${n_traceid}" -gt 0 ]]; then
  ok "traces are flowing to the OTel Collector"
else
  warn "no trace IDs visible yet — wait 5-10s and re-check, or look at 'make traces'"
fi

# ----------------------------------------------------------------------- #
hr "6. Mapping — telemetry fields to Envoy/HCM artifacts"

cat <<'EOF' | sed 's/^/    /'
EnvoyProxy.telemetry field              Envoy artifact
--------------------------------------- ----------------------------------------
accessLog.settings[].format.type=JSON   HCM access_log[] with JsonFormat
   .format.json                           formatter; each key/value becomes a JSON field
   .sinks[].type=File / .file.path        StdoutAccessLog / FileAccessLog typed_config
   .sinks[].type=OpenTelemetry            envoy.access_loggers.open_telemetry

metrics.prometheus                       admin endpoint :19001/stats/prometheus
                                          (always on; this knob toggles it off)
metrics.matches[]                        stats_config.stats_matcher (filter what
                                          gets exposed for scraping)

tracing.samplingRate                     listener.tracing.random_sampling.value
tracing.provider.type=OpenTelemetry      HCM http_filters: envoy.filters.http.router
                                          + bootstrap tracing.http.name = otel
                                          (cluster -> the configured backendRefs)
tracing.customTags[]                     listener.tracing.custom_tags
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make logs          # tail the live JSON access log stream"
echo "  make traces        # tail the OTel Collector's debug output"
echo "  make metrics       # snapshot a handful of envoy metrics"
echo "  make admin         # port-forward Envoy admin (open /config_dump etc.)"
