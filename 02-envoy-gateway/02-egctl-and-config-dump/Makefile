.PHONY: up verify down status admin pf

NS      := demo
GATEWAY := inspect

up: check-cluster
	kubectl apply -f manifests/gateway.yaml -f manifests/httproute.yaml
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/hello-base

verify:
	./verify.sh

down:
	kubectl delete -f manifests/ --ignore-not-found

status:
	@kubectl -n $(NS) get gateway/$(GATEWAY) httproute -o wide

# Open a port-forward to a data-plane pod's admin endpoint.
admin:
	@pod=$$(kubectl -n envoy-gateway-system get pods \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  echo "port-forward $$pod 19000:19000" && \
	  kubectl -n envoy-gateway-system port-forward $$pod 19000:19000

# Port-forward the data-plane Service to localhost:8080.
pf:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc 8080:80

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
