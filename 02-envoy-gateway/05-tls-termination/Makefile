.PHONY: up verify down status pf admin logs certs clean-certs check-cluster

NS      := demo
GATEWAY := secure
LOCAL_PORT := 18443

up: check-cluster certs
	@# Materialize the cert + key into TLS Secrets in the demo ns.
	@# --dry-run=client + apply -f - so re-running `make up` is idempotent.
	kubectl create secret tls hello-tls -n $(NS) \
	  --cert=certs/hello.local.crt --key=certs/hello.local.key \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret tls api-tls -n $(NS) \
	  --cert=certs/api.local.crt --key=certs/api.local.key \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f manifests/
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/hello
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/api

verify:
	./verify.sh

down:
	kubectl delete -f manifests/ --ignore-not-found
	kubectl delete secret hello-tls api-tls -n $(NS) --ignore-not-found

# `make up` triggers this automatically. Use directly if you want to
# regenerate certs (delete certs/ first and re-run).
certs:
	./gen-certs.sh

clean-certs:
	rm -rf certs

status:
	@printf "\n\033[1;34m== Gateway ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== Gateway listener status ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) \
	  -o jsonpath='{range .status.listeners[*]}  {.name}: attachedRoutes={.attachedRoutes} conditions=[{range .conditions[*]}{.type}={.status} {end}]{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== HTTPRoutes ==\033[0m\n"
	@kubectl -n $(NS) get httproute -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== TLS Secrets ==\033[0m\n"
	@kubectl -n $(NS) get secret hello-tls api-tls 2>/dev/null || true
	@printf "\n\033[1;34m== Data plane ==\033[0m\n"
	@kubectl -n envoy-gateway-system get pods,svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) 2>/dev/null || true

# Port-forward the HTTPS listener. Use --resolve to actually validate
# the cert chain — see README + verify.sh.
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
	  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== HTTPRoute conditions ==\033[0m\n"
	@for r in hello api ; do \
	  echo "$$r:" ; \
	  kubectl -n $(NS) get httproute "$$r" \
	    -o jsonpath='{range .status.parents[0].conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true ; \
	done

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@command -v openssl >/dev/null 2>&1 || { \
	  echo "openssl missing — install it (brew install openssl)" ; exit 1 ; }
