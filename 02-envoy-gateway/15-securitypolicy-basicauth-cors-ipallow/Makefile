.PHONY: up verify down status pf admin logs check-cluster

NS         := demo
GATEWAY    := security-mix
LOCAL_PORT := 18160

up: check-cluster
	kubectl apply -f manifests/basic-auth-secret.yaml
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/httproute.yaml
	kubectl apply -f manifests/clienttrafficpolicy.yaml
	kubectl apply -f manifests/securitypolicy.yaml
	kubectl wait --for=condition=Programmed --timeout=180s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/security-mix

verify:
	./verify.sh

down:
	-kubectl -n $(NS) delete securitypolicy security-mix --ignore-not-found
	-kubectl -n $(NS) delete clienttrafficpolicy security-mix-xff --ignore-not-found
	-kubectl delete -f manifests/httproute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found
	-kubectl delete -f manifests/basic-auth-secret.yaml --ignore-not-found

status:
	@printf "\n\033[1;34m== Gateway + HTTPRoute ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@kubectl -n $(NS) get httproute security-mix -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== Policies ==\033[0m\n"
	@kubectl -n $(NS) get clienttrafficpolicy,securitypolicy -o wide 2>/dev/null || true
	@kubectl -n $(NS) get securitypolicy security-mix \
	  -o jsonpath='{range .status.ancestors[0].conditions[*]}  sp:  {.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null || true
	@kubectl -n $(NS) get clienttrafficpolicy security-mix-xff \
	  -o jsonpath='{range .status.ancestors[0].conditions[*]}  ctp: {.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null || true
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
	@printf "\n\033[1;34m== SecurityPolicy status ==\033[0m\n"
	@kubectl -n $(NS) get securitypolicy security-mix -o yaml 2>/dev/null \
	  | yq '.status' 2>/dev/null || true

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
