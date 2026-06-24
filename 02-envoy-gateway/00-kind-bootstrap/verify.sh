#!/usr/bin/env bash
#
# Health-check the bootstrap. Confirms the cluster, Envoy Gateway, and
# the helloworld Deployment are all where we expect them. Doesn't
# create any Gateway/HTTPRoute — that's example 01's job.

set -euo pipefail

CLUSTER="envoy-gateway-examples"

hr()   { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '   \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------- #
hr "1. kind cluster"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  ok "cluster '${CLUSTER}' present"
else
  fail "no kind cluster named '${CLUSTER}' — run 'make up'"
fi

if kubectl cluster-info --context "kind-${CLUSTER}" >/dev/null 2>&1; then
  ok "kubectl reaches the cluster"
else
  fail "kubectl cannot reach the cluster"
fi

# ----------------------------------------------------------------------- #
hr "2. Gateway API CRDs (experimental channel)"
for crd in gatewayclasses gateways httproutes \
           grpcroutes referencegrants \
           xlistenersets backendtlspolicies; do
  fqn="${crd}.gateway.networking.k8s.io"
  if kubectl get crd "${fqn}" >/dev/null 2>&1; then
    ok "CRD ${fqn}"
  else
    fail "CRD ${fqn} missing — re-run 'make install-gw-api'"
  fi
done

# ----------------------------------------------------------------------- #
hr "3. Envoy Gateway controller"
if kubectl -n envoy-gateway-system get deploy envoy-gateway >/dev/null 2>&1; then
  ok "deploy/envoy-gateway exists"
else
  fail "envoy-gateway deployment missing — re-run 'make install-eg'"
fi

ready=$(kubectl -n envoy-gateway-system get deploy envoy-gateway \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
[[ "${ready}" -ge 1 ]] && ok "envoy-gateway has ${ready} ready replica(s)" \
                       || fail "envoy-gateway not ready"

if kubectl get gatewayclass eg >/dev/null 2>&1; then
  ok "GatewayClass 'eg' exists"
else
  ok "GatewayClass 'eg' not yet created (example 01 creates it)"
fi

# ----------------------------------------------------------------------- #
hr "4. helloworld in the demo namespace"
ready=$(kubectl -n demo get deploy helloworld \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
[[ "${ready}" -ge 1 ]] && ok "helloworld has ${ready} ready replica(s)" \
                       || fail "helloworld not ready"

if kubectl -n demo get svc helloworld >/dev/null 2>&1; then
  ok "svc/helloworld present"
else
  fail "svc/helloworld missing — re-run 'make install-helloworld'"
fi

note=$(kubectl -n demo run curlpod --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -sS --max-time 5 http://helloworld.demo:8080/ 2>/dev/null || true)
if echo "${note}" | grep -q '"msg"'; then
  ok "in-cluster curl to helloworld returned a JSON response"
else
  fail "in-cluster curl to helloworld failed"
fi

hr "Done. Cluster is ready for the rest of Phase 2."
echo "Next:"
echo "  cd ../01-helloworld-gateway && make up && make verify"
