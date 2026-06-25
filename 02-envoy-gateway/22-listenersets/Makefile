.PHONY: up verify down status pf-blue pf-green pf-base admin logs check-cluster

NS_PLATFORM := platform
GATEWAY     := shared
LOCAL_BASE  := 18220
LOCAL_BLUE  := 18221
LOCAL_GREEN := 18222

up: check-cluster
	# Namespaces first (admission-controller race; see PROGRESS.md).
	kubectl apply -f manifests/00-namespaces.yaml
	# Backends per team.
	kubectl apply -f manifests/blue-backend.yaml
	kubectl apply -f manifests/green-backend.yaml
	kubectl wait --for=condition=Available --timeout=120s -n team-blue  deploy/blue-backend
	kubectl wait --for=condition=Available --timeout=120s -n team-green deploy/green-backend
	# Base Gateway, then per-team XListenerSets + routes.
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/listenerset-blue.yaml
	kubectl apply -f manifests/listenerset-green.yaml
	kubectl apply -f manifests/httproute-blue.yaml
	kubectl apply -f manifests/httproute-green.yaml
	kubectl wait --for=condition=Programmed --timeout=180s -n $(NS_PLATFORM) gateway/$(GATEWAY)

verify:
	./verify.sh

down:
	-kubectl delete -f manifests/httproute-green.yaml --ignore-not-found
	-kubectl delete -f manifests/httproute-blue.yaml --ignore-not-found
	-kubectl delete -f manifests/listenerset-green.yaml --ignore-not-found
	-kubectl delete -f manifests/listenerset-blue.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found
	-kubectl delete -f manifests/green-backend.yaml --ignore-not-found
	-kubectl delete -f manifests/blue-backend.yaml --ignore-not-found
	-kubectl delete -f manifests/00-namespaces.yaml --ignore-not-found

status:
	@printf "\n\033[1;34m== Gateway ==\033[0m\n"
	@kubectl -n $(NS_PLATFORM) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== Listener-level status (base + every XListenerSet's listener) ==\033[0m\n"
	@kubectl -n $(NS_PLATFORM) get gateway/$(GATEWAY) \
	  -o jsonpath='{range .status.listeners[*]}  {.name}: attachedRoutes={.attachedRoutes} programmed={.conditions[?(@.type=="Programmed")].status}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== XListenerSets ==\033[0m\n"
	@kubectl get xlistenerset -A 2>/dev/null || true
	@printf "\n\033[1;34m== HTTPRoutes ==\033[0m\n"
	@kubectl get httproute -A 2>/dev/null | grep -E 'blue|green|NAMESPACE' || true
	@printf "\n\033[1;34m== Data plane ==\033[0m\n"
	@kubectl -n envoy-gateway-system get pods,svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) 2>/dev/null || true

# Three port-forwards for the three listeners on the one data plane.
pf-base:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc $(LOCAL_BASE):80

pf-blue:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc $(LOCAL_BLUE):8080

pf-green:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc $(LOCAL_GREEN):8081

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
	@kubectl -n $(NS_PLATFORM) get gateway/$(GATEWAY) \
	  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== XListenerSet conditions ==\033[0m\n"
	@for entry in team-blue/blue team-green/green ; do \
	  ns=$${entry%/*} ; name=$${entry#*/} ; \
	  echo "$$entry:" ; \
	  kubectl -n "$$ns" get xlistenerset "$$name" \
	    -o jsonpath='{range .status.conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true ; \
	done

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl get crd xlistenersets.gateway.networking.x-k8s.io >/dev/null 2>&1 || { \
	  echo "XListenerSet CRD missing — bootstrap must install experimental Gateway API CRDs" ; exit 1 ; }
