.PHONY: up verify down status pf pf-dex admin logs check-cluster

NS         := demo
GATEWAY    := oidc-gateway
APP_PORT   := 18150
DEX_PORT   := 5556        # browser-facing port == in-cluster Service port

up: check-cluster
	kubectl apply -f manifests/dex.yaml
	kubectl apply -f manifests/dex-client-secret.yaml
	kubectl wait --for=condition=Available --timeout=120s -n $(NS) deploy/dex
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/httproute.yaml
	kubectl apply -f manifests/securitypolicy.yaml
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/oidc-protect

verify:
	./verify.sh

down:
	-kubectl -n $(NS) delete securitypolicy oidc-protect --ignore-not-found
	-kubectl delete -f manifests/httproute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found
	-kubectl delete -f manifests/dex-client-secret.yaml --ignore-not-found
	-kubectl delete -f manifests/dex.yaml --ignore-not-found

status:
	@printf "\n\033[1;34m== Gateway + HTTPRoute ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@kubectl -n $(NS) get httproute oidc-protect -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== SecurityPolicy ==\033[0m\n"
	@kubectl -n $(NS) get securitypolicy -o wide 2>/dev/null || true
	@kubectl -n $(NS) get securitypolicy oidc-protect \
	  -o jsonpath='{range .status.ancestors[0].conditions[*]}  {.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== Dex ==\033[0m\n"
	@kubectl -n $(NS) get deploy,svc,pods -l app=dex 2>/dev/null || true
	@printf "\n\033[1;34m== Data plane ==\033[0m\n"
	@kubectl -n envoy-gateway-system get pods,svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) 2>/dev/null || true

# Port-forward the GATEWAY so the browser can reach `app.local`.
pf:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc $(APP_PORT):80

# Port-forward DEX so the browser can reach the login form.
pf-dex:
	kubectl -n $(NS) port-forward svc/dex $(DEX_PORT):5556

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
	@printf "\n\033[1;34m== Dex logs ==\033[0m\n"
	@kubectl -n $(NS) logs -l app=dex --tail=20 --prefix 2>/dev/null || true
	@printf "\n\033[1;34m== SecurityPolicy status ==\033[0m\n"
	@kubectl -n $(NS) get securitypolicy oidc-protect -o yaml 2>/dev/null \
	  | yq '.status' 2>/dev/null || true

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
