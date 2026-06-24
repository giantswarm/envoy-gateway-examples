.PHONY: up verify down status pf admin

NS      := demo
GATEWAY := routing

up: check-cluster
	kubectl apply -f manifests/
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/routing
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/api-local

verify:
	./verify.sh

down:
	kubectl delete -f manifests/ --ignore-not-found

status:
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide
	@kubectl -n $(NS) get httproute -o wide
	@printf "\n\033[1;34m== HTTPRoute conditions ==\033[0m\n"
	@kubectl -n $(NS) get httproute routing \
	  -o jsonpath='{range .status.parents[*].conditions[*]}  routing:  {.type}={.status}  {.reason}{"\n"}{end}' 2>/dev/null || true
	@kubectl -n $(NS) get httproute api-local \
	  -o jsonpath='{range .status.parents[*].conditions[*]}  api-local: {.type}={.status}  {.reason}{"\n"}{end}' 2>/dev/null || true

pf:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc 8080:80

admin:
	@pod=$$(kubectl -n envoy-gateway-system get pods \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward $$pod 19000:19000

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
