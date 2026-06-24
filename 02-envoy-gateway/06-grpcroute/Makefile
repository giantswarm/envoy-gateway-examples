.PHONY: up verify down status pf admin logs check-cluster check-grpcurl

NS         := grpc-demo
GATEWAY    := rpc
LOCAL_PORT := 18090

up: check-cluster
	# Apply in dependency order. `kubectl apply -f manifests/` doesn't
	# guarantee file order across resources, and the namespace-lifecycle
	# admission controller can reject the Gateway before the
	# just-created Namespace propagates through the apiserver cache.
	# Splitting the apply (and waiting for the backend) makes it
	# deterministic.
	kubectl apply -f manifests/grpcbin.yaml
	kubectl wait --for=condition=Available --timeout=120s -n $(NS) deploy/grpcbin
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/grpcroute.yaml
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) grpcroute/grpcbin

verify: check-grpcurl
	./verify.sh

down:
	# Reverse order on the way out; the Namespace cascade-deletes
	# anything we miss anyway.
	-kubectl delete -f manifests/grpcroute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found
	-kubectl delete -f manifests/grpcbin.yaml --ignore-not-found

status:
	@printf "\n\033[1;34m== Gateway ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== GRPCRoute ==\033[0m\n"
	@kubectl -n $(NS) get grpcroute -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== grpcbin backend ==\033[0m\n"
	@kubectl -n $(NS) get deploy,svc,pods -l app=grpcbin 2>/dev/null || true
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
	@printf "\n\033[1;34m== grpcbin pod logs ==\033[0m\n"
	@kubectl -n $(NS) logs -l app=grpcbin --tail=20 --prefix 2>/dev/null || true
	@printf "\n\033[1;34m== Gateway conditions ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) \
	  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== GRPCRoute conditions ==\033[0m\n"
	@kubectl -n $(NS) get grpcroute grpcbin \
	  -o jsonpath='{range .status.parents[0].conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }

check-grpcurl:
	@command -v grpcurl >/dev/null 2>&1 || { \
	  echo "grpcurl missing. Install with: brew install grpcurl" ; \
	  echo "(or: go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest)" ; \
	  exit 1 ; }
