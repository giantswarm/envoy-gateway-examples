.PHONY: up verify down status pf admin metrics traces logs check-cluster

NS         := demo
GATEWAY    := observed
LOCAL_PORT := 18210

up: check-cluster
	# OTel Collector must be Ready BEFORE the EnvoyProxy points at
	# it — otherwise Envoy logs trace export failures until it's up.
	kubectl apply -f manifests/otel-collector.yaml
	kubectl wait --for=condition=Available --timeout=120s -n $(NS) deploy/otel-collector
	kubectl apply -f manifests/envoyproxy.yaml
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/httproute.yaml
	kubectl wait --for=condition=Programmed --timeout=180s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/observed

verify:
	./verify.sh

down:
	-kubectl delete -f manifests/httproute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found
	-kubectl delete -f manifests/envoyproxy.yaml --ignore-not-found
	-kubectl delete -f manifests/otel-collector.yaml --ignore-not-found

status:
	@printf "\n\033[1;34m== Gateway + HTTPRoute ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@kubectl -n $(NS) get httproute observed -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== EnvoyProxy ==\033[0m\n"
	@kubectl -n $(NS) get envoyproxy observed-proxy 2>/dev/null || true
	@printf "\n\033[1;34m== OTel Collector ==\033[0m\n"
	@kubectl -n $(NS) get deploy,svc,pods -l app=otel-collector 2>/dev/null || true
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

# Tail JSON access logs.
logs:
	@printf "\n\033[1;34m== JSON access logs (envoy stdout) ==\033[0m\n"
	@kubectl -n envoy-gateway-system logs -f --prefix=false --tail=20 \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) -c envoy

# Print Prometheus metrics. Envoy distroless has no shell so we
# port-forward and curl from the host instead of kubectl exec.
metrics:
	@pod=$$(kubectl -n envoy-gateway-system get pods \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  --field-selector=status.phase=Running \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward $$pod 19001:19001 >/dev/null 2>&1 & \
	  PF=$$! ; \
	  trap "kill -TERM $$PF 2>/dev/null || true" EXIT ; \
	  for _ in 1 2 3 4 5 6 7 8 9 10 ; do \
	    (echo > /dev/tcp/localhost/19001) 2>/dev/null && break ; \
	    sleep 0.3 ; \
	  done ; \
	  curl -sS http://localhost:19001/stats/prometheus \
	    | grep -E '^(envoy_http_downstream_rq_total|envoy_cluster_upstream_rq_total)' \
	    | head -20

# Tail OTel Collector trace exports.
traces:
	@printf "\n\033[1;34m== OTel Collector debug export (traces) ==\033[0m\n"
	@kubectl -n $(NS) logs -f --prefix=false --tail=50 \
	  -l app=otel-collector

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
