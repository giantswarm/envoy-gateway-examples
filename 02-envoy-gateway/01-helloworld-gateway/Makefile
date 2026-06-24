.PHONY: up verify down logs status pf admin

NS      := demo
GATEWAY := eg

up: check-cluster
	kubectl apply -f manifests/
	@echo ">> waiting for Gateway to be Programmed..."
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	@echo ">> waiting for HTTPRoute Accepted condition..."
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/helloworld

verify:
	./verify.sh

down:
	kubectl delete -f manifests/ --ignore-not-found

# ---------- diagnostics ---------- #

status:
	@printf "\n\033[1;34m== GatewayClass ==\033[0m\n"
	@kubectl get gatewayclass eg -o wide || true
	@printf "\n\033[1;34m== Gateway ==\033[0m\n"
	@kubectl -n $(NS) get gateway $(GATEWAY) -o wide || true
	@kubectl -n $(NS) get gateway $(GATEWAY) -o jsonpath='{range .status.conditions[*]}  {.type}={.status}  {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== HTTPRoute ==\033[0m\n"
	@kubectl -n $(NS) get httproute helloworld -o wide || true
	@kubectl -n $(NS) get httproute helloworld -o jsonpath='{range .status.parents[*].conditions[*]}  {.type}={.status}  {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== Generated Envoy data-plane pods ==\033[0m\n"
	@kubectl -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) -o wide 2>/dev/null || true

logs:
	@pod=$$(kubectl -n envoy-gateway-system get pods \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system logs -f $$pod

# Port-forward the data-plane service to localhost:8080. Run in another
# terminal and curl localhost:8080.
pf:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  echo "port-forward svc/$$svc 8080:80" && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc 8080:80

# Port-forward the Envoy admin port (:19000) of one data-plane pod.
admin:
	@pod=$$(kubectl -n envoy-gateway-system get pods \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  echo "port-forward $$pod 19000:19000" && \
	  kubectl -n envoy-gateway-system port-forward $$pod 19000:19000

# ---------- bootstrap presence ---------- #

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; \
	  exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing in namespace $(NS) — run '../00-kind-bootstrap/make up' first" ; \
	  exit 1 ; }
