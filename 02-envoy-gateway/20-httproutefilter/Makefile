.PHONY: up verify down status pf admin logs check-cluster

NS         := demo
GATEWAY    := route-filter
LOCAL_PORT := 18200

up: check-cluster
	# HTTPRouteFilters must exist before the HTTPRoute references
	# them, or EG marks the route ResolvedRefs=False until the next
	# reconcile. Apply filters first.
	kubectl apply -f manifests/filter-rewrite.yaml
	kubectl apply -f manifests/filter-healthz.yaml
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/httproute.yaml
	kubectl wait --for=condition=Programmed --timeout=180s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/route-filter

verify:
	./verify.sh

down:
	-kubectl delete -f manifests/httproute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found
	-kubectl delete -f manifests/filter-healthz.yaml --ignore-not-found
	-kubectl delete -f manifests/filter-rewrite.yaml --ignore-not-found

status:
	@printf "\n\033[1;34m== Gateway + HTTPRoute ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@kubectl -n $(NS) get httproute route-filter -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== HTTPRouteFilters ==\033[0m\n"
	@kubectl -n $(NS) get httproutefilter -o wide 2>/dev/null || true
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
	@printf "\n\033[1;34m== HTTPRouteFilter status ==\033[0m\n"
	@for f in users-rewrite healthz-direct ; do \
	  echo "  $$f:" ; \
	  kubectl -n $(NS) get httproutefilter "$$f" -o yaml 2>/dev/null \
	    | yq '.status' 2>/dev/null || true ; \
	done
	@printf "\n\033[1;34m== HTTPRoute conditions ==\033[0m\n"
	@kubectl -n $(NS) get httproute route-filter \
	  -o jsonpath='{range .status.parents[0].conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
