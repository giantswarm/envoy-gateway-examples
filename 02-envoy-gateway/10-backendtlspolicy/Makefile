.PHONY: up verify down status pf admin logs certs clean-certs check-cluster

NS         := tls-upstream-demo
GATEWAY    := secure-up
LOCAL_PORT := 18110

up: check-cluster certs
	kubectl apply -f manifests/00-namespace.yaml
	# Backend cert -> kubernetes.io/tls Secret (nginx mounts it).
	kubectl create secret tls secure-backend-cert -n $(NS) \
	  --cert=certs/backend.crt --key=certs/backend.key \
	  --dry-run=client -o yaml | kubectl apply -f -
	# CA cert -> plain ConfigMap with key ca.crt (BackendTLSPolicy
	# expects exactly this key).
	kubectl create configmap secure-backend-ca -n $(NS) \
	  --from-file=ca.crt=certs/ca.crt \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f manifests/secure-backend.yaml
	kubectl wait --for=condition=Available --timeout=120s -n $(NS) deploy/secure-backend
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/httproute.yaml
	kubectl apply -f manifests/backendtlspolicy.yaml
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/secure

verify:
	./verify.sh

down:
	-kubectl delete -f manifests/backendtlspolicy.yaml --ignore-not-found
	-kubectl delete -f manifests/httproute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found
	-kubectl delete -f manifests/secure-backend.yaml --ignore-not-found
	-kubectl delete secret  secure-backend-cert -n $(NS) --ignore-not-found
	-kubectl delete configmap secure-backend-ca -n $(NS) --ignore-not-found
	-kubectl delete -f manifests/00-namespace.yaml --ignore-not-found

certs:
	./gen-certs.sh

clean-certs:
	rm -rf certs

status:
	@printf "\n\033[1;34m== Gateway + HTTPRoute ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@kubectl -n $(NS) get httproute -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== BackendTLSPolicy ==\033[0m\n"
	@kubectl -n $(NS) get backendtlspolicy -o wide 2>/dev/null || true
	@kubectl -n $(NS) get backendtlspolicy secure-backend-tls \
	  -o jsonpath='{range .status.ancestors[0].conditions[*]}  {.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null || true
	@printf "\n\033[1;34m== CA ConfigMap + backend Secret ==\033[0m\n"
	@kubectl -n $(NS) get configmap secure-backend-ca secret secure-backend-cert 2>/dev/null || true
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
	@printf "\n\033[1;34m== nginx backend logs ==\033[0m\n"
	@kubectl -n $(NS) logs -l app=secure-backend --tail=20 --prefix 2>/dev/null || true
	@printf "\n\033[1;34m== BackendTLSPolicy conditions ==\033[0m\n"
	@kubectl -n $(NS) get backendtlspolicy secure-backend-tls -o yaml 2>/dev/null \
	  | yq '.status' 2>/dev/null || true

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@command -v openssl >/dev/null 2>&1 || { echo "openssl missing" ; exit 1 ; }
