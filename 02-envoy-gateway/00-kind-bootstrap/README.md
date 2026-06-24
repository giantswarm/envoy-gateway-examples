# 00 — kind cluster + Envoy Gateway bootstrap

This is the **shared foundation** for every example in Phase 2. It:

1. Creates a single-node `kind` cluster named `envoy-gateway-examples`.
2. Builds the helloworld Flask app from
   [`apps/helloworld/`](../../apps/helloworld/) and loads it into the
   cluster (no registry needed).
3. Installs the **Gateway API** CRDs from the **experimental channel**
   (so `XListenerSet`, `BackendTLSPolicy`, `GRPCRoute`, etc. are all
   present — we'll exercise them later).
4. Installs **Envoy Gateway** via its official Helm chart.
5. Deploys helloworld into the `demo` namespace as a 3-replica
   Deployment + Service.

Every subsequent Phase 2 example **assumes this cluster is up**. They
each `kubectl apply` their own Gateway / HTTPRoute / Policy / etc.
manifests on top, run a verify, then clean up only their own resources.

By the end of this example you should be able to answer:

- What pieces does Envoy Gateway need on a vanilla Kubernetes cluster?
- Where does Gateway API come from and what's the experimental channel?
- How do I confirm Envoy Gateway is up and ready to translate manifests?
- How do I tear down everything cleanly?

## Prerequisites

- **`docker`** running.
- **`kind`** v0.20+ (`brew install kind` / `go install sigs.k8s.io/kind@latest`).
- **`kubectl`** v1.28+.
- **`helm`** v3.10+.

Versions pinned in the Makefile:

- Gateway API CRDs: `v1.2.0` (experimental channel).
- Envoy Gateway helm chart: `v1.4.0` (the version that introduced
  `XListenerSet` support — see example 22).

To bump either, edit the variables at the top of the Makefile.

## Run it

```bash
make up           # one-shot: kind + image + CRDs + EG + helloworld (~3 min)
make verify       # health-check the four layers above
make status       # quick overview of the cluster
make down         # delete the kind cluster entirely
```

To re-run any single step (e.g. after fiddling with the helm chart):

```bash
make install-eg            # just re-install Envoy Gateway
make install-helloworld    # just re-apply the helloworld manifests
make install-gw-api        # just re-install the Gateway API CRDs
make image                 # rebuild + reload the helloworld image
```

## What the four layers look like

```
┌─────────────────────────────────────────────────────────────┐
│                kind cluster: envoy-gateway-examples         │
│                                                             │
│  ┌──────────────────────────────┐  ┌─────────────────────┐  │
│  │ envoy-gateway-system         │  │ demo                │  │
│  │                              │  │                     │  │
│  │  Deploy/envoy-gateway        │  │  Deploy/helloworld  │  │
│  │   (control plane)            │  │   (3 replicas)      │  │
│  │                              │  │  Svc/helloworld     │  │
│  │   GatewayClass "eg"          │  │   :8080             │  │
│  │   (registered by EG)         │  │                     │  │
│  └──────────────────────────────┘  └─────────────────────┘  │
│                                                             │
│  Gateway API CRDs (experimental channel):                   │
│    gateways / httproutes / grpcroutes / tlsroutes /         │
│    tcproutes / udproutes / referencegrants /                │
│    backendtlspolicies / xlistenersets / ...                 │
│                                                             │
│  Envoy Gateway CRDs:                                        │
│    envoyproxies / envoyextensionpolicies /                  │
│    backendtrafficpolicies / clienttrafficpolicies /         │
│    securitypolicies / envoypatchpolicies / ...              │
└─────────────────────────────────────────────────────────────┘
```

`envoy-gateway` (in `envoy-gateway-system`) is the **control plane**.
It watches Gateway API resources, translates them into Envoy xDS, and
auto-creates a **data-plane** Deployment (an Envoy instance) per
Gateway you define. We'll see the first one when we apply a `Gateway`
in example 01.

## The image flow

```
apps/helloworld/Dockerfile                       (source)
       │
       │ docker build -t envoy-gateway-examples/helloworld:tutorial
       ▼
local docker image cache
       │
       │ kind load docker-image
       ▼
kind cluster's containerd image store
       │
       │ Deployment pulls with imagePullPolicy: Never
       ▼
Running pod in the demo namespace
```

`kind load docker-image` is the cheap-and-cheerful way to get an image
into a kind cluster without standing up a registry. The Deployment uses
`imagePullPolicy: Never` so kubelet won't try to fetch it from a
registry; if you change the tag, you must re-run `make image`.

## Why the experimental channel?

Gateway API has two CRD channels:

| Channel       | Includes                                                                                  |
|---------------|-------------------------------------------------------------------------------------------|
| `standard`    | GA resources: `Gateway`, `HTTPRoute`, `GatewayClass`, `ReferenceGrant`, `GRPCRoute`.       |
| `experimental`| Standard + `TLSRoute`, `TCPRoute`, `UDPRoute`, `BackendTLSPolicy`, `XListenerSet`, and the most-recent additions. |

Phase 2 walks through every Envoy Gateway feature, including
`XListenerSet` (example 22). That means we need experimental. The
trade-off is that experimental CRDs can have breaking changes between
versions — pin to a specific Gateway API release like we do here.

## Verify

`make verify` walks four checkpoints:

1. **kind cluster** — present and reachable via `kubectl`.
2. **Gateway API CRDs** — every required CRD is installed and
   established.
3. **Envoy Gateway controller** — `deploy/envoy-gateway` has at least
   one ready replica.
4. **helloworld** — deployment ready, service reachable from inside
   the cluster (the script `kubectl run`s a one-shot curl pod).

If any step fails, the error message tells you which `make` target to
re-run.

## Cleanup

```bash
make down         # nukes the cluster; subsequent `make up` rebuilds everything
```

This deletes ALL state — Envoy Gateway, all the manifests applied by
later examples, the helloworld backend, the cluster itself.

## Common pitfalls

| Symptom                                              | Fix                                                                                |
|------------------------------------------------------|------------------------------------------------------------------------------------|
| `kind: command not found`                            | `brew install kind` or `go install sigs.k8s.io/kind@v0.23.0`.                      |
| `helm install` errors on `oci://`                    | Helm < 3.10 doesn't support OCI charts. `brew upgrade helm`.                      |
| Pods stuck in `ImagePullBackOff` for `helloworld`    | `make image` again — `kind load` only loads to the cluster you're targeting.       |
| Envoy Gateway pods crashloop                         | Check `kubectl logs -n envoy-gateway-system deploy/envoy-gateway`. Usually an admission-webhook conflict if you already have ingress-nginx. |
| `make up` hangs at "waiting for envoy-gateway"       | Slow image pull; give it another minute. Then `make install-eg` again if needed.   |

## Next

- Move to [`../01-helloworld-gateway/`](../01-helloworld-gateway/) for
  the first real `Gateway` + `HTTPRoute` example.
- The full Phase 2 list lives in [`../README.md`](../README.md).
