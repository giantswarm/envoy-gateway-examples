.PHONY: up down reset status verify image kind-up kind-down install-gw-api install-eg install-default-envoyproxy install-gatewayclass install-helloworld

# Bootstrap orchestrator. `make up` is the one-liner customers run; the
# pieces below let you re-run any single step.

CLUSTER          := envoy-gateway-examples
HELLOWORLD_IMAGE := envoy-gateway-examples/helloworld:tutorial
GATEWAY_API_VER  := v1.2.0
EG_HELM_VERSION  := v1.4.0
REPO_ROOT        := $(shell git rev-parse --show-toplevel)

# Explicit list of Gateway API CRD short names — deleted by full FQN
# during reset / clean-install. Listing them by name avoids relying on
# `kubectl get crd | grep ...` (which has been unreliable in practice
# when the bundle-version label is missing or output formatting varies).
GW_API_CRDS := gatewayclasses gateways httproutes grpcroutes tlsroutes tcproutes udproutes referencegrants backendtlspolicies xlistenersets

# Order matters: EG's helm chart bundles the STANDARD-channel Gateway
# API CRDs and applies them with its own field manager. We install
# helm FIRST, then layer the experimental-channel CRDs on top with
# `kubectl apply --server-side --force-conflicts` so kubectl takes
# ownership without conflicting.
up: kind-up image install-eg install-gw-api install-default-envoyproxy install-gatewayclass install-helloworld
	@echo
	@echo "  Cluster ready. Move to ../01-helloworld-gateway/ to deploy your first Gateway."

down: kind-down

# Wipe Envoy Gateway + Gateway API CRDs WITHOUT deleting the cluster.
# Use when a prior `make up` left things half-installed (e.g. helm
# install conflicted with pre-existing CRDs). After `make reset`, run
# `make up` to re-bootstrap from a clean state.
#
# We delete CRDs by *name suffix*, not by label, because chart-bundled
# CRDs sometimes ship without the `gateway.networking.k8s.io/bundle-version`
# label (depends on which release flavor was installed).
reset:
	@echo ">> uninstalling helm release (if any)..."
	-helm uninstall eg -n envoy-gateway-system 2>/dev/null
	@echo ">> deleting Gateway API CRDs by name..."
	@for n in $(GW_API_CRDS); do \
	  echo "   $$n.gateway.networking.k8s.io" ; \
	  kubectl delete crd $$n.gateway.networking.k8s.io --ignore-not-found --wait=true >/dev/null 2>&1 ; \
	done
	@echo ">> deleting Envoy Gateway CRDs..."
	@for n in envoyproxies envoyextensionpolicies backendtrafficpolicies clienttrafficpolicies securitypolicies envoypatchpolicies httproutefilters backends; do \
	  echo "   $$n.gateway.envoyproxy.io" ; \
	  kubectl delete crd $$n.gateway.envoyproxy.io --ignore-not-found --wait=true >/dev/null 2>&1 ; \
	done
	@echo ">> deleting envoy-gateway-system namespace..."
	-kubectl delete ns envoy-gateway-system --ignore-not-found
	@echo "done. Now run: make up"

# ---------------------------------------------------------------------- #
# Tooling presence — fail fast with a clear hint.
# ---------------------------------------------------------------------- #
check-tools:
	@for t in kind kubectl helm docker; do \
	  command -v $$t >/dev/null 2>&1 || { echo "missing: $$t"; exit 1; } ; \
	done

# ---------------------------------------------------------------------- #
# 1. kind cluster
# ---------------------------------------------------------------------- #
kind-up: check-tools
	@if kind get clusters | grep -qx "$(CLUSTER)"; then \
	  echo ">> kind cluster '$(CLUSTER)' already up"; \
	else \
	  echo ">> creating kind cluster '$(CLUSTER)'..." ; \
	  kind create cluster --name "$(CLUSTER)" --config ./kind-config.yaml ; \
	fi
	@kubectl cluster-info --context "kind-$(CLUSTER)" >/dev/null

kind-down:
	@if kind get clusters | grep -qx "$(CLUSTER)"; then \
	  kind delete cluster --name "$(CLUSTER)" ; \
	else \
	  echo "no cluster '$(CLUSTER)' to delete" ; \
	fi

# ---------------------------------------------------------------------- #
# 2. helloworld image — built locally, kind-loaded into the cluster.
# ---------------------------------------------------------------------- #
image:
	@echo ">> building $(HELLOWORLD_IMAGE)..."
	docker build -q -t $(HELLOWORLD_IMAGE) $(REPO_ROOT)/apps/helloworld
	@echo ">> loading image into kind cluster..."
	kind load docker-image $(HELLOWORLD_IMAGE) --name $(CLUSTER)

# ---------------------------------------------------------------------- #
# 3. Gateway API CRDs (experimental channel — includes XListenerSet,
#    BackendTLSPolicy, and other future-looking CRDs we need).
# ---------------------------------------------------------------------- #
install-gw-api:
	@echo ">> applying Gateway API $(GATEWAY_API_VER) CRDs (experimental, server-side)..."
	# --server-side  : use SSA so the manager is "kubectl"
	# --force-conflicts : take ownership of fields previously owned by
	#                     helm (the chart shipped standard-channel CRDs).
	kubectl apply --server-side --force-conflicts \
	  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VER)/experimental-install.yaml"
	@kubectl wait --for=condition=Established --timeout=60s \
	    crd/gatewayclasses.gateway.networking.k8s.io \
	    crd/gateways.gateway.networking.k8s.io \
	    crd/httproutes.gateway.networking.k8s.io

# ---------------------------------------------------------------------- #
# 4. Envoy Gateway — installed via the official helm chart.
# ---------------------------------------------------------------------- #
install-eg:
	@# If a prior `make up` failed mid-way, Gateway API CRDs already
	@# exist with `kubectl` as the field manager and helm's install of
	@# its own bundled CRDs conflicts. We detect this (no DEPLOYED helm
	@# release yet) and wipe the offending CRDs before installing.
	@# A DEPLOYED release on subsequent runs short-circuits — helm
	@# upgrades don't reinstall CRDs from crds/, so no conflict.
	@status=$$(helm status eg -n envoy-gateway-system -o json 2>/dev/null \
	          | jq -r '.info.status' 2>/dev/null || echo "missing") ; \
	if [ "$$status" != "deployed" ]; then \
	  echo ">> helm release status: $${status:-missing} — clean install required" ; \
	  helm uninstall eg -n envoy-gateway-system 2>/dev/null || true ; \
	  for n in $(GW_API_CRDS); do \
	    echo "   deleting $$n.gateway.networking.k8s.io..." ; \
	    kubectl delete crd $$n.gateway.networking.k8s.io --ignore-not-found --wait=true >/dev/null 2>&1 ; \
	  done ; \
	fi
	@echo ">> installing Envoy Gateway $(EG_HELM_VERSION)..."
	helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
	  --version $(EG_HELM_VERSION) \
	  -n envoy-gateway-system --create-namespace
	@echo ">> waiting for envoy-gateway controller to be ready..."
	kubectl wait --for=condition=Available --timeout=180s \
	    -n envoy-gateway-system deploy/envoy-gateway

# ---------------------------------------------------------------------- #
# 5. Default EnvoyProxy — sets the auto-generated data-plane Service
#    type to ClusterIP so Gateways report Programmed=True on kind
#    (no LB controller). Must exist before the GatewayClass that
#    references it via parametersRef.
# ---------------------------------------------------------------------- #
install-default-envoyproxy:
	@echo ">> applying default EnvoyProxy (ClusterIP service)..."
	kubectl apply -f manifests/default-envoyproxy.yaml

# ---------------------------------------------------------------------- #
# 6. GatewayClass `eg` — applied explicitly so every Phase 2 example
#    can rely on it existing regardless of chart-template variance.
# ---------------------------------------------------------------------- #
install-gatewayclass:
	@echo ">> applying GatewayClass 'eg'..."
	kubectl apply -f manifests/gatewayclass.yaml
	kubectl wait --for=condition=Accepted --timeout=60s gatewayclass/eg

# ---------------------------------------------------------------------- #
# 6. helloworld Deployment + Service in the `demo` namespace.
# ---------------------------------------------------------------------- #
install-helloworld:
	@echo ">> deploying helloworld..."
	kubectl apply -f manifests/helloworld.yaml
	kubectl wait --for=condition=Available --timeout=120s \
	    -n demo deploy/helloworld

# ---------------------------------------------------------------------- #
# Diagnostics
# ---------------------------------------------------------------------- #
status:
	@printf "\n\033[1;34m== cluster ==\033[0m\n"
	@kind get clusters 2>/dev/null || true
	@printf "\n\033[1;34m== nodes ==\033[0m\n"
	@kubectl get nodes -o wide 2>/dev/null || true
	@printf "\n\033[1;34m== envoy-gateway-system ==\033[0m\n"
	@kubectl get pods,svc -n envoy-gateway-system 2>/dev/null || true
	@printf "\n\033[1;34m== gateway-api CRDs ==\033[0m\n"
	@kubectl get crd | grep gateway.networking || true
	@printf "\n\033[1;34m== demo namespace ==\033[0m\n"
	@kubectl get all -n demo 2>/dev/null || true

verify:
	./verify.sh
