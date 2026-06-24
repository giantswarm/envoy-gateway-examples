.PHONY: up verify down status pf admin diff logs check-cluster

NS      := demo
GATEWAY := tuned

up: check-cluster
	# EnvoyProxy MUST exist before the Gateway is reconciled — apply
	# in order so EG doesn't first generate the data plane with
	# defaults and then reshape it a second later.
	kubectl apply -f manifests/envoyproxy.yaml
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/httproute.yaml
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/helloworld

verify:
	./verify.sh

down:
	kubectl delete -f manifests/ --ignore-not-found

status:
	@printf "\n\033[1;34m== EnvoyProxy CRs ==\033[0m\n"
	@kubectl get envoyproxy -A 2>/dev/null || true
	@printf "\n\033[1;34m== Gateway ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide
	@printf "\n\033[1;34m== Auto-generated data plane ==\033[0m\n"
	@kubectl -n envoy-gateway-system get deploy,pods,svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) 2>/dev/null || true

pf:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc 18080:80

admin:
	@pod=$$(kubectl -n envoy-gateway-system get pods \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward $$pod 19000:19000

# Side-by-side: this Gateway's deploy vs example-01's default data plane.
# Run `cd ../01-helloworld-gateway && make up` first to populate the
# baseline.
diff:
	@echo "tuned (this example)"
	@kubectl -n envoy-gateway-system get deploy \
	  -l gateway.envoyproxy.io/owning-gateway-name=tuned \
	  -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas,CPU_LIMIT:.spec.template.spec.containers[0].resources.limits.cpu,MEM_LIMIT:.spec.template.spec.containers[0].resources.limits.memory 2>/dev/null || true
	@echo "eg (example 01 baseline)"
	@kubectl -n envoy-gateway-system get deploy \
	  -l gateway.envoyproxy.io/owning-gateway-name=eg \
	  -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas,CPU_LIMIT:.spec.template.spec.containers[0].resources.limits.cpu,MEM_LIMIT:.spec.template.spec.containers[0].resources.limits.memory 2>/dev/null || true

# Dump everything you need to diagnose a misbehaving data plane.
# Paste the output when reporting an issue.
logs:
	@printf "\n\033[1;34m== pods ==\033[0m\n"
	@kubectl -n envoy-gateway-system get pods \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== last 60 lines of envoy container logs ==\033[0m\n"
	@kubectl -n envoy-gateway-system logs \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -c envoy --tail=60 --prefix 2>/dev/null || true
	@printf "\n\033[1;34m== data-plane Service endpoints ==\033[0m\n"
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) ; \
	  [ -n "$$svc" ] && kubectl -n envoy-gateway-system get endpoints "$$svc" -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== helloworld backend endpoints ==\033[0m\n"
	@kubectl -n $(NS) get endpoints helloworld -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== Gateway conditions ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== HTTPRoute conditions ==\033[0m\n"
	@kubectl -n $(NS) get httproute helloworld -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== local port 18080 (anyone else holding it?) ==\033[0m\n"
	@lsof -i :18080 2>/dev/null || echo "  (nothing or lsof unavailable)"

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
