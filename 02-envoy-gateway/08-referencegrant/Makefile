.PHONY: up verify down status pf admin logs certs clean-certs check-cluster

NS         := apps
BACKEND_NS := demo
GATEWAY    := crossns
LOCAL_PORT := 18443

up: check-cluster certs
	# Namespace + ReferenceGrants first (cross-namespace edges must be
	# permitted before the routes try to resolve their refs).
	kubectl apply -f manifests/00-namespace.yaml
	kubectl create secret tls apps-tls -n $(BACKEND_NS) \
	  --cert=certs/apps.local.crt --key=certs/apps.local.key \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f manifests/refgrant-secret.yaml
	kubectl apply -f manifests/refgrant-service.yaml
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/httproute.yaml
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/app
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}'=True \
	  --timeout=60s -n $(NS) httproute/app

verify:
	./verify.sh

down:
	-kubectl delete -f manifests/httproute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found
	-kubectl delete -f manifests/refgrant-service.yaml --ignore-not-found
	-kubectl delete -f manifests/refgrant-secret.yaml --ignore-not-found
	-kubectl delete secret apps-tls -n $(BACKEND_NS) --ignore-not-found
	-kubectl delete -f manifests/00-namespace.yaml --ignore-not-found

certs:
	./gen-certs.sh

clean-certs:
	rm -rf certs

status:
	@printf "\n\033[1;34m== Namespaces ==\033[0m\n"
	@kubectl get ns apps $(BACKEND_NS) 2>/dev/null || true
	@printf "\n\033[1;34m== Gateway (in apps) ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@kubectl -n $(NS) get gateway/$(GATEWAY) \
	  -o jsonpath='{range .status.listeners[*]}  {.name}: programmed={.conditions[?(@.type=="Programmed")].status} resolvedRefs={.conditions[?(@.type=="ResolvedRefs")].status}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== HTTPRoute (in apps) ==\033[0m\n"
	@kubectl -n $(NS) get httproute -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== ReferenceGrants (in $(BACKEND_NS)) ==\033[0m\n"
	@kubectl -n $(BACKEND_NS) get referencegrant -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== TLS Secret (in $(BACKEND_NS)) ==\033[0m\n"
	@kubectl -n $(BACKEND_NS) get secret apps-tls 2>/dev/null || true
	@printf "\n\033[1;34m== Data plane ==\033[0m\n"
	@kubectl -n envoy-gateway-system get pods,svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) 2>/dev/null || true

pf:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc $(LOCAL_PORT):443

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
	  -o jsonpath='{range .status.listeners[*]}{.name}: {range .conditions[*]}{.type}={.status} {.reason}: {.message}{"\n  "}{end}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== HTTPRoute conditions ==\033[0m\n"
	@kubectl -n $(NS) get httproute app \
	  -o jsonpath='{range .status.parents[0].conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(BACKEND_NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@command -v openssl >/dev/null 2>&1 || { echo "openssl missing" ; exit 1 ; }
