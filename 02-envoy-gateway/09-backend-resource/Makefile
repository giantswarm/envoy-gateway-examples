.PHONY: up verify down status pf admin logs check-cluster ensure-backend-api

NS              := backend-demo
GATEWAY         := backend-demo
LOCAL_PORT      := 18100
EG_HELM_VERSION := v1.4.0       # must match 00-kind-bootstrap

up: check-cluster ensure-backend-api
	# Apply Namespace first to avoid the admission-controller race
	# documented in PROGRESS.md (and example 06's Makefile).
	kubectl apply -f manifests/00-namespace.yaml
	kubectl apply -f manifests/backend-external.yaml
	kubectl apply -f manifests/backend-fqdn.yaml
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/httproute.yaml
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/backends

verify:
	./verify.sh

down:
	-kubectl delete -f manifests/httproute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found
	-kubectl delete -f manifests/backend-fqdn.yaml --ignore-not-found
	-kubectl delete -f manifests/backend-external.yaml --ignore-not-found
	-kubectl delete -f manifests/00-namespace.yaml --ignore-not-found

status:
	@printf "\n\033[1;34m== Backends ==\033[0m\n"
	@kubectl -n $(NS) get backend -o wide 2>/dev/null || true
	@kubectl -n $(NS) get backend \
	  -o jsonpath='{range .items[*]}  {.metadata.name}: {range .status.conditions[*]}{.type}={.status} {end}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== Gateway ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== HTTPRoute ==\033[0m\n"
	@kubectl -n $(NS) get httproute -o wide 2>/dev/null || true
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
	@printf "\n\033[1;34m== Gateway conditions ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) \
	  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== HTTPRoute conditions ==\033[0m\n"
	@kubectl -n $(NS) get httproute backends \
	  -o jsonpath='{range .status.parents[0].conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== Backend conditions ==\033[0m\n"
	@for b in example-com helloworld-fqdn ; do \
	  echo "$$b:" ; \
	  kubectl -n $(NS) get backend "$$b" \
	    -o jsonpath='{range .status.conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true ; \
	done

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n demo get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing in demo ns — run '../00-kind-bootstrap/make up'" ; exit 1 ; }

# Backend (the CRD) is gated behind a feature flag in the EG controller
# config — off by default. Bootstrap installs EG with the flag set; for
# clusters bootstrapped before that change, this target self-heals via
# helm upgrade --reuse-values. Idempotent.
ensure-backend-api:
	@if kubectl -n envoy-gateway-system get configmap envoy-gateway-config \
	    -o jsonpath='{.data.envoy-gateway\.yaml}' 2>/dev/null \
	    | grep -qE 'enableBackend:[[:space:]]*true' ; then \
	  echo ">> EG Backend API already enabled" ; \
	else \
	  echo ">> EG Backend API is OFF — enabling via helm upgrade..." ; \
	  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
	    --version $(EG_HELM_VERSION) \
	    -n envoy-gateway-system \
	    --reuse-values \
	    --set config.envoyGateway.extensionApis.enableBackend=true ; \
	  echo ">> restarting EG controller so the new config takes effect..." ; \
	  kubectl -n envoy-gateway-system rollout restart deploy/envoy-gateway ; \
	  kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=120s ; \
	  echo ">> giving the controller a moment to reconcile existing Backends..." ; \
	  sleep 5 ; \
	fi
