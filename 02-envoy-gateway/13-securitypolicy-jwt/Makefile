.PHONY: up verify down status pf admin logs keys clean-keys check-cluster

NS         := demo
GATEWAY    := jwt-gateway
LOCAL_PORT := 18140

up: check-cluster keys
	kubectl apply -f manifests/gateway.yaml
	kubectl apply -f manifests/httproute.yaml
	@# Render securitypolicy.yaml by substituting the JWKS inline.
	@# We use `|` as the sed delimiter because JSON content doesn't
	@# contain it. The JSON is quoted with single quotes in YAML, so
	@# its embedded double-quotes are safe.
	@jwks=$$(jq -c '.' keys/jwks.json) && \
	  sed "s|__JWKS_INLINE__|$$jwks|" manifests/securitypolicy.yaml \
	  | kubectl apply -f -
	kubectl wait --for=condition=Programmed --timeout=60s -n $(NS) gateway/$(GATEWAY)
	kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
	  --timeout=60s -n $(NS) httproute/jwt-protect

verify:
	./verify.sh

down:
	-kubectl -n $(NS) delete securitypolicy jwt-protect --ignore-not-found
	-kubectl delete -f manifests/httproute.yaml --ignore-not-found
	-kubectl delete -f manifests/gateway.yaml --ignore-not-found

keys:
	./gen-keys.sh

clean-keys:
	rm -rf keys

status:
	@printf "\n\033[1;34m== Gateway + HTTPRoute ==\033[0m\n"
	@kubectl -n $(NS) get gateway/$(GATEWAY) -o wide 2>/dev/null || true
	@kubectl -n $(NS) get httproute jwt-protect -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== SecurityPolicy ==\033[0m\n"
	@kubectl -n $(NS) get securitypolicy -o wide 2>/dev/null || true
	@kubectl -n $(NS) get securitypolicy jwt-protect \
	  -o jsonpath='{range .status.ancestors[0].conditions[*]}  {.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null || true
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
	@kubectl -n $(NS) get securitypolicy jwt-protect -o yaml 2>/dev/null \
	  | yq '.status' 2>/dev/null || true

check-cluster:
	@kubectl get gatewayclass eg >/dev/null 2>&1 || { \
	  echo "GatewayClass 'eg' missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@kubectl -n $(NS) get svc helloworld >/dev/null 2>&1 || { \
	  echo "svc/helloworld missing — run '../00-kind-bootstrap/make up' first" ; exit 1 ; }
	@command -v openssl >/dev/null 2>&1 || { echo "openssl missing" ; exit 1 ; }
	@command -v jq      >/dev/null 2>&1 || { echo "jq missing"      ; exit 1 ; }
