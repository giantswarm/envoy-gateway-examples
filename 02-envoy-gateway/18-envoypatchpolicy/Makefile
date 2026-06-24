.PHONY: up verify down status pf admin logs check-cluster ensure-patch-api

NS              := demo
GATEWAY         := patched
LOCAL_PORT      := 18180
EG_HELM_VERSION := v1.4.0          # must match 00-kind-bootstrap

up: check-cluster ensure-patch-api
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/httproute.yaml
	kubectl apply -f manifests/envoypatchpolicy.yaml
	kubectl wait --for=condition=Programmed --timeout=180s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/patched

verify:
	./verify.sh

down:
	-kubectl -n $(NS) delete envoypatchpolicy patched --ignore-not-found
	-kubectl delete -f manifests/httproute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found

# EnvoyPatchPolicy is gated behind a feature flag in the EG
# controller config (off by default). The bootstrap install
# enables it; for clusters bootstrapped BEFORE that fix, this
# target self-heals via helm upgrade --reuse-values. Idempotent.
ensure-patch-api:
	@if kubectl -n envoy-gateway-system get configmap envoy-gateway-config \
	    -o jsonpath='{.data.envoy-gateway\.yaml}' 2>/dev/null \
	    | grep -qE 'enableEnvoyPatchPolicy:[[:space:]]*true' ; then \
	  echo ">> EG EnvoyPatchPolicy API already enabled" ; \
	else \
	  echo ">> EG EnvoyPatchPolicy API is OFF — enabling via helm upgrade..." ; \
	  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
	    --version $(EG_HELM_VERSION) \
	    -n envoy-gateway-system \
	    --reuse-values \
	    --set config.envoyGateway.extensionApis.enableEnvoyPatchPolicy=true ; \
	  echo ">> restarting EG controller..." ; \
	  kubectl -n envoy-gateway-system rollout restart deploy/envoy-gateway ; \
	  kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=120s ; \
	  sleep 5 ; \
	fi

status:
	@printf "\n\033[1;34m== Gateway + HTTPRoute ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@kubectl -n $(NS) get httproute patched -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== EnvoyPatchPolicy ==\033[0m\n"
	@kubectl -n $(NS) get envoypatchpolicy -o wide 2>/dev/null || true
	@kubectl -n $(NS) get envoypatchpolicy patched \
	  -o jsonpath='{range .status.conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== Data plane ==\033[0m\n"
	@kubectl -n envoy-gateway-system get pods,svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) 2>/dev/null || true

pf:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc $(LOCAL_PORT):80

admin:
	@pod=$$(kubectl -n envoy-gateway-system get pods \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward $$pod 19000:19000

logs:
	@printf "\n\033[1;34m== pods ==\033[0m\n"
	@kubectl -n envoy-gateway-system get pods \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== last 40 lines of envoy logs ==\033[0m\n"
	@kubectl -n envoy-gateway-system logs \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) -c envoy --tail=40 --prefix 2>/dev/null || true
	@printf "\n\033[1;34m== EnvoyPatchPolicy status ==\033[0m\n"
	@kubectl -n $(NS) get envoypatchpolicy patched -o yaml 2>/dev/null \
	  | yq '.status' 2>/dev/null || true

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
