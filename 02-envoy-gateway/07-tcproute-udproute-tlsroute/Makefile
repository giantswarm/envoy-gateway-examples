.PHONY: up verify down status pf-tcp pf-tls admin logs certs clean-certs check-cluster

NS         := l4-demo
GATEWAY    := l4
LOCAL_TCP  := 19001        # localhost port for TCPRoute test (tcp-echo)
LOCAL_TLS  := 18443        # localhost port for TLSRoute test (nginx-pass)

up: check-cluster certs
	@# Apply in dependency order — see PROGRESS.md note on Namespace
	@# admission-controller races.
	kubectl apply -f manifests/00-namespace.yaml
	@# Cert Secret for the TLS-passthrough backend (NOT the Gateway).
	kubectl create secret tls tls-backend-cert -n $(NS) \
	  --cert=certs/tls.local.crt --key=certs/tls.local.key \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f manifests/tcp-echo.yaml
	kubectl apply -f manifests/coredns.yaml
	kubectl apply -f manifests/tls-backend.yaml
	kubectl wait --for=condition=Available --timeout=120s -n $(NS) \
	  deploy/tcp-echo deploy/coredns deploy/tls-backend
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/tcproute.yaml
	kubectl apply -f manifests/udproute.yaml
	kubectl apply -f manifests/tlsroute.yaml
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	@for kind in tcproutes/tcp-echo udproutes/coredns tlsroutes/tls-backend ; do \
	  kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	    --timeout=60s -n $(NS) $$kind ; \
	done

verify:
	./verify.sh

down:
	-kubectl delete -f manifests/tlsroute.yaml --ignore-not-found
	-kubectl delete -f manifests/udproute.yaml --ignore-not-found
	-kubectl delete -f manifests/tcproute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found
	-kubectl delete -f manifests/tls-backend.yaml --ignore-not-found
	-kubectl delete -f manifests/coredns.yaml --ignore-not-found
	-kubectl delete -f manifests/tcp-echo.yaml --ignore-not-found
	-kubectl delete secret tls-backend-cert -n $(NS) --ignore-not-found
	-kubectl delete -f manifests/00-namespace.yaml --ignore-not-found

certs:
	./gen-certs.sh

clean-certs:
	rm -rf certs

status:
	@printf "\n\033[1;34m== Gateway + listeners ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@kubectl -n $(NS) get gateway/$(GATEWAY) \
	  -o jsonpath='{range .status.listeners[*]}  {.name}: attachedRoutes={.attachedRoutes} programmed={.conditions[?(@.type=="Programmed")].status} resolvedRefs={.conditions[?(@.type=="ResolvedRefs")].status}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== L4 routes ==\033[0m\n"
	@kubectl -n $(NS) get tcproute,udproute,tlsroute -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== Backends ==\033[0m\n"
	@kubectl -n $(NS) get deploy,svc 2>/dev/null || true
	@printf "\n\033[1;34m== Data plane ==\033[0m\n"
	@kubectl -n envoy-gateway-system get pods,svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) 2>/dev/null || true

# TCP and TLS work over kubectl port-forward. UDP doesn't (kubectl
# port-forward is TCP-only), so we test that one from inside the
# cluster via an ephemeral debug pod (see verify.sh).
pf-tcp:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc $(LOCAL_TCP):9001

pf-tls:
	@svc=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=$(GATEWAY) \
	  -o jsonpath='{.items[0].metadata.name}') && \
	  kubectl -n envoy-gateway-system port-forward svc/$$svc $(LOCAL_TLS):8443

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
	@printf "\n\033[1;34m== L4 route conditions ==\033[0m\n"
	@for kind in tcproute/tcp-echo udproute/coredns tlsroute/tls-backend ; do \
	  echo "$$kind:" ; \
	  kubectl -n $(NS) get $$kind \
	    -o jsonpath='{range .status.parents[0].conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true ; \
	done

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@command -v openssl >/dev/null 2>&1 || { echo "openssl missing" ; exit 1 ; }
	@command -v nc      >/dev/null 2>&1 || { echo "nc (netcat) missing" ; exit 1 ; }
