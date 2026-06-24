.PHONY: up verify down image status pf admin logs check-cluster

NS              := demo
GATEWAY         := extauth-gateway
LOCAL_PORT      := 18170
AUTHZ_IMAGE     := envoy-gateway-examples/authz:tutorial
CLUSTER         := envoy-gateway-examples

up: check-cluster image
	kubectl apply -f manifests/authz.yaml
	kubectl wait --for=condition=Available --timeout=120s -n $(NS) deploy/authz
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/httproute.yaml
	kubectl apply -f manifests/securitypolicy.yaml
	kubectl wait --for=condition=Programmed --timeout=180s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/extauth-protect

# Build the authz image locally and kind-load it so the cluster can
# pull without a registry.
image:
	@echo ">> building $(AUTHZ_IMAGE)..."
	docker build -q -t $(AUTHZ_IMAGE) authz/
	@echo ">> loading image into kind cluster..."
	kind load docker-image $(AUTHZ_IMAGE) --name $(CLUSTER)

verify:
	./verify.sh

down:
	-kubectl -n $(NS) delete securitypolicy extauth-protect --ignore-not-found
	-kubectl delete -f manifests/httproute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found
	-kubectl delete -f manifests/authz.yaml --ignore-not-found

status:
	@printf "\n\033[1;34m== Gateway + HTTPRoute ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@kubectl -n $(NS) get httproute extauth-protect -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== SecurityPolicy ==\033[0m\n"
	@kubectl -n $(NS) get securitypolicy -o wide 2>/dev/null || true
	@kubectl -n $(NS) get securitypolicy extauth-protect \
	  -o jsonpath='{range .status.ancestors[0].conditions[*]}  {.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== authz service ==\033[0m\n"
	@kubectl -n $(NS) get deploy,svc,pods -l app=authz 2>/dev/null || true
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
	@printf "\n\033[1;34m== authz logs ==\033[0m\n"
	@kubectl -n $(NS) logs -l app=authz --tail=20 --prefix 2>/dev/null || true
	@printf "\n\033[1;34m== SecurityPolicy status ==\033[0m\n"
	@kubectl -n $(NS) get securitypolicy extauth-protect -o yaml 2>/dev/null \
	  | yq '.status' 2>/dev/null || true

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@command -v docker >/dev/null 2>&1 || { echo "docker missing" ; exit 1 ; }
	@command -v kind   >/dev/null 2>&1 || { echo "kind missing"   ; exit 1 ; }
