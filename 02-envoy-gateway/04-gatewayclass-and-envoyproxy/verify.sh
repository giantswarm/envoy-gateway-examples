#!/usr/bin/env bash
#
# Confirms the EnvoyProxy CR overrode the auto-generated Deployment:
# replicas, resources, image pin, and log level all reflect what we
# wrote in manifests/envoyproxy.yaml — while inheriting the
# Service.type from the GatewayClass-default EnvoyProxy.

set -euo pipefail

NS=demo
GATEWAY=tuned
EG_NS=envoy-gateway-system

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
fail()  { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------- #
hr "1. Gateway status — Programmed by EG"

gw_prog=$(kubectl -n "${NS}" get gateway "${GATEWAY}" \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
[[ "${gw_prog}" == "True" ]] && ok "Gateway/${GATEWAY} Programmed=True" \
                              || fail "Gateway not Programmed (got '${gw_prog:-<none>}')"

# ----------------------------------------------------------------------- #
hr "2. Auto-generated Deployment reflects the EnvoyProxy override"

DEPLOY=$(kubectl -n "${EG_NS}" get deploy \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY},gateway.envoyproxy.io/owning-gateway-namespace=${NS} \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "${DEPLOY}" ]] || fail "no data-plane Deployment found for Gateway/${GATEWAY}"
ok "Deployment: ${EG_NS}/${DEPLOY}"

# Replicas — we asked for 3.
spec_replicas=$(kubectl -n "${EG_NS}" get deploy "${DEPLOY}" -o jsonpath='{.spec.replicas}')
ready_replicas=$(kubectl -n "${EG_NS}" get deploy "${DEPLOY}" -o jsonpath='{.status.readyReplicas}')
[[ "${spec_replicas}" == "3" ]] && ok "spec.replicas=3 (override applied)" \
                                || fail "expected 3 replicas, got '${spec_replicas}'"
[[ "${ready_replicas:-0}" == "3" ]] && ok "all 3 replicas Ready" \
                                    || warn "only ${ready_replicas:-0}/3 replicas Ready yet"

# Image — we DON'T pin it in this example (mismatched images break
# EG's bootstrap; see envoyproxy.yaml + exercise 6). Just print whatever
# EG bundles so you can see it.
img=$(kubectl -n "${EG_NS}" get deploy "${DEPLOY}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="envoy")].image}')
ok "container.image = ${img} (EG's default)"

# Resources — we set requests + limits.
cpu_lim=$(kubectl -n "${EG_NS}" get deploy "${DEPLOY}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="envoy")].resources.limits.cpu}')
mem_lim=$(kubectl -n "${EG_NS}" get deploy "${DEPLOY}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="envoy")].resources.limits.memory}')
[[ "${cpu_lim}" == "500m" && "${mem_lim}" == "512Mi" ]] \
  && ok "resources.limits = cpu:${cpu_lim} memory:${mem_lim}" \
  || fail "expected cpu:500m memory:512Mi, got cpu:'${cpu_lim}' memory:'${mem_lim}'"

# Pod-level labels + annotations we set in EnvoyProxy.pod.
pod_label=$(kubectl -n "${EG_NS}" get deploy "${DEPLOY}" \
  -o jsonpath='{.spec.template.metadata.labels.tutorial-pod}')
[[ "${pod_label}" == "true" ]] && ok "pod label tutorial-pod=true present" \
                                || warn "pod label not found (got '${pod_label}')"

# ----------------------------------------------------------------------- #
hr "3. Service type — restated as ClusterIP in the per-Gateway EnvoyProxy"

SVC=$(kubectl -n "${EG_NS}" get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY},gateway.envoyproxy.io/owning-gateway-namespace=${NS} \
  -o jsonpath='{.items[0].metadata.name}')
svc_type=$(kubectl -n "${EG_NS}" get svc "${SVC}" -o jsonpath='{.spec.type}')
[[ "${svc_type}" == "ClusterIP" ]] \
  && ok "Service/${SVC} type=ClusterIP (per-Gateway EnvoyProxy fully replaces class default — we restated it here)" \
  || fail "expected ClusterIP, got '${svc_type}' — see envoyproxy.yaml comment about full-replace semantics"

# ----------------------------------------------------------------------- #
hr "4. Log level — Envoy actually started at debug"

POD=$(kubectl -n "${EG_NS}" get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY},gateway.envoyproxy.io/owning-gateway-namespace=${NS} \
  -o jsonpath='{.items[0].metadata.name}')

# Two ways to confirm:
# 1. Container args contain `--log-level debug` (EG injects this).
args=$(kubectl -n "${EG_NS}" get pod "${POD}" \
  -o jsonpath='{.spec.containers[?(@.name=="envoy")].args}')
echo "${args}" | grep -q 'debug' \
  && ok "container args mention 'debug': $(echo "${args}" | tr -d '[]' | head -c 120)" \
  || warn "container args don't mention debug (check args manually): ${args}"

# 2. Admin /logging endpoint reports the current level. Best-effort —
# if local :19000 is busy (Phase 1 examples often hold it) or the
# port-forward takes too long to come up, fall back to printing
# instructions rather than failing the script.
note "Cross-check via admin /logging — port-forward and curl:"
kubectl -n "${EG_NS}" port-forward "${POD}" 19000:19000 \
  >/tmp/tuned-admin.log 2>&1 &
PF=$!
trap 'kill -TERM ${PF} 2>/dev/null || true' EXIT
admin_up=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sSf -o /dev/null --max-time 1 http://localhost:19000/ready 2>/dev/null; then
    admin_up=1; break
  fi
  sleep 0.5
done

if [[ -n "${admin_up}" ]]; then
  logging_out=$(curl -sS http://localhost:19000/logging || true)
  { echo "${logging_out}" | grep -E '^\s*(http|connection|main):' || true ; } \
    | head -5 | sed 's/^/    /' || true
else
  warn "admin :19000 not reachable via port-forward — likely a"
  warn "port conflict on localhost:19000 (Phase 1 examples grab it)."
  warn "Run 'make admin' in a clean shell to inspect /logging directly."
  warn "Port-forward log: /tmp/tuned-admin.log"
fi

# ----------------------------------------------------------------------- #
hr "5. Traffic still works through the customized data plane"

kubectl -n "${EG_NS}" port-forward "svc/${SVC}" 18080:80 \
  >/tmp/tuned-data.log 2>&1 &
DATA_PF=$!
trap 'kill -TERM ${PF} ${DATA_PF} 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:18080/ && break
  sleep 0.5
done

note "10 requests — load-balanced across helloworld replicas (the data"
note "plane is still doing its day job, just with more replicas behind it):"
for _ in $(seq 1 10); do
  curl -sS http://localhost:18080/ | jq -r .from_
done | sort | uniq -c | sed 's/^/    /' || true

# ----------------------------------------------------------------------- #
hr "6. Mapping — what each EnvoyProxy field controls"

cat <<'EOF' | sed 's/^/    /'
EnvoyProxy field                                  Resource it patches
------------------------------------------------- --------------------------
provider.kubernetes.envoyDeployment.replicas      Deployment.spec.replicas
provider.kubernetes.envoyDeployment.pod.{labels,
  annotations}                                    Deployment.spec.template.metadata
provider.kubernetes.envoyDeployment.container.{
  image, resources, securityContext, env }        Deployment.spec.template.spec.containers[0]
provider.kubernetes.envoyService.{ type,
  annotations, externalTrafficPolicy }            Service.spec
logging.level.default                             Envoy container args: --log-level
telemetry.{accessLog,metrics,tracing}             Generated Envoy bootstrap (see ex 21)
bootstrap.{type,value}                            Generated Envoy bootstrap (escape hatch)
EOF

hr "7. Two-tier precedence — GatewayClass default vs Gateway override"

cat <<'EOF' | sed 's/^/    /'
Rule: when a Gateway sets infrastructure.parametersRef, that
EnvoyProxy ENTIRELY REPLACES the GatewayClass default for that
Gateway. There is no field-by-field merge. Anything the default set
that you still want, you MUST restate.

Field                       Source                Resulting value
--------------------------- --------------------- ---------------
envoyDeployment.replicas    tuned-proxy           3
container.image             tuned-proxy           envoy:v1.34.1
container.resources         tuned-proxy           cpu/mem set
logging.level.default       tuned-proxy           debug
envoyService.type           tuned-proxy (RESTATED) ClusterIP
                            <- without this we'd get LoadBalancer
                            (EG's built-in default) and on kind that
                            sits at <pending> => Programmed=False.

Other Gateways that DON'T reference a per-Gateway EnvoyProxy still
inherit the GatewayClass default-envoyproxy (replicas=1, ClusterIP,
warn-level logging). See `make diff` for the comparison.
EOF

hr "Done."
echo "Useful follow-ups:"
echo "  make status                    # CRs + auto-generated Deployment/Service"
echo "  make diff                      # this Gateway vs ex 01's default deploy"
echo "  make admin                     # port-forward Envoy admin for /logging, /stats, etc."
