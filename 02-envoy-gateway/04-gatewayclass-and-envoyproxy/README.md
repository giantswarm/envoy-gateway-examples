# 04 — GatewayClass and the EnvoyProxy CR

Up to here every Gateway you've created produced the SAME shape of
data plane: 1 replica, default resources, default log level, the
bundled Envoy image. That's fine for `hello-world`, but real
workloads want HA, sized limits, debug logs while iterating, and
sometimes a pinned proxy version.

This is what the **`EnvoyProxy` CR** is for: a declarative way to
shape the auto-generated `Deployment` and `Service` that Envoy
Gateway provisions for each `Gateway`.

By the end of this example you should be able to answer:

- What is the `EnvoyProxy` CR and what does it control?
- What's the difference between attaching it to a **GatewayClass**
  vs a **Gateway**?
- How does a per-Gateway EnvoyProxy stack with the GatewayClass
  default? What gets merged, what gets replaced?
- How do you bump replicas, set resource limits, enable debug
  logging, pin the Envoy image?
- Where does each field of `EnvoyProxy.spec` end up in the
  generated `Deployment` / `Service`?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done [`01-helloworld-gateway`](../01-helloworld-gateway/),
  [`02-egctl-and-config-dump`](../02-egctl-and-config-dump/),
  [`03-httproute-matching-and-filters`](../03-httproute-matching-and-filters/).

## Run it

```bash
make up           # apply EnvoyProxy + Gateway + HTTPRoute, wait for Programmed
make verify       # 7-step check: replicas, image, resources, log level, traffic
make status       # all related resources at a glance
make diff         # this example's deploy vs example 01's baseline
make down
```

## Two attachment points

```
GatewayClass eg
  └── spec.parametersRef → EnvoyProxy default-envoyproxy   # cluster default
                                                            (applies to every Gateway)
Gateway tuned                                               #
  └── spec.infrastructure.parametersRef → EnvoyProxy tuned-proxy   # per-Gateway override
```

| Attachment                       | Scope                       | Namespace requirement       |
|----------------------------------|-----------------------------|-----------------------------|
| `GatewayClass.spec.parametersRef`| Every Gateway using class   | Explicit `namespace:` field; usually `envoy-gateway-system` |
| `Gateway.spec.infrastructure.parametersRef` | This Gateway only           | **Must be in the same namespace as the Gateway** |

The bootstrap installs the cluster-default EnvoyProxy with
`envoyService.type: ClusterIP` (needed on kind, no LB controller).
**When this Gateway references `tuned-proxy` it stops using the
class default entirely** — Envoy Gateway does NOT field-by-field
merge the two. See the [merge semantics](#merge-semantics--what-overrides-what)
section below; the per-Gateway EnvoyProxy has to restate
`envoyService.type: ClusterIP` to keep working on kind.

## What you can put in `EnvoyProxy.spec`

```yaml
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 3
        pod:
          labels: {...}
          annotations: {...}
          nodeSelector: {...}
          tolerations: [...]
          topologySpreadConstraints: [...]
        container:
          image: envoyproxy/envoy:vX.Y.Z
          resources: { requests, limits }
          securityContext: {...}
          env: [...]
        strategy:
          type: RollingUpdate
      envoyService:
        type: ClusterIP | LoadBalancer | NodePort
        annotations: {...}
        externalTrafficPolicy: Local | Cluster
        loadBalancerIP: ...
        loadBalancerSourceRanges: [...]
      envoyHpa:                     # auto-scaling
        minReplicas: ...
        maxReplicas: ...
        metrics: [...]
      envoyPDB:                     # PodDisruptionBudget
        minAvailable: 1

  logging:
    level:
      default: warn | info | debug | trace
      # Per-component overrides:
      # http: info
      # connection: warn

  telemetry:                        # example 21 covers this
    accessLog:
      settings: [...]
    metrics:
      prometheus: { disable: false }
    tracing:
      provider: { type: OpenTelemetry, ... }

  bootstrap:                        # raw Envoy bootstrap patch
    type: Merge | Replace
    value: |
      ...

  shutdown:                         # graceful-shutdown timing
    drainTimeout: 60s
    minDrainDuration: 10s

  filterOrder:                      # reorder built-in filters (rare)
    - name: envoy.filters.http.fault
      before: envoy.filters.http.cors
```

Almost every field is optional; the chart-bundled defaults are
sensible.

## Merge semantics — what overrides what

When a Gateway references a per-Gateway EnvoyProxy AND the
GatewayClass has a default EnvoyProxy:

**The per-Gateway EnvoyProxy ENTIRELY REPLACES the GatewayClass
default for that Gateway.** There is no field-by-field merge; there
is no deep merge of nested blocks; there is no array merge. From
EG's docs: *"If both are specified, the configuration in the
Gateway's `infrastructure.parametersRef` takes precedence."*
"Takes precedence" means "replaces", not "overlays".

In practice this means: **anything the class default sets that you
still want, you must restate in the per-Gateway EnvoyProxy.** The
classic kind footgun:

- Class default: `envoyService.type: ClusterIP` (so Gateways become
  Programmed on a cluster with no LB controller).
- Your per-Gateway EnvoyProxy: replicas=3, resources, logging — but
  no `envoyService:` block.
- Result: Gateway uses EG's built-in default `envoyService.type:
  LoadBalancer`, EXTERNAL-IP stays `<pending>`, Gateway reports
  `Programmed=False reason: AddressNotAssigned`. Pods are running
  fine — the conditions just can't reach True.

That's why this example's `manifests/envoyproxy.yaml` explicitly
restates `envoyService.type: ClusterIP`.

The safest pattern in practice: keep the GatewayClass-default
EnvoyProxy *minimal* (just the must-have global settings) AND have
per-Gateway overrides restate every must-have field they care
about. Treat the two as independent specs, not as base + patch.

## The pieces in this example

`manifests/envoyproxy.yaml` — replicas=3, pod labels/annotations,
resources, debug logging. We deliberately do NOT pin the container
image; see exercise 6 for why and how if you want to try it.

`manifests/gateway.yaml` — Gateway `tuned` with
`infrastructure.parametersRef` pointing at `tuned-proxy` in the same
namespace.

`manifests/httproute.yaml` — boring catch-all → helloworld, so the
focus stays on the data-plane CR.

## Walkthrough — what to inspect

After `make up`:

```bash
# Three replicas now (vs 1 by default):
kubectl -n envoy-gateway-system get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=tuned

# Image (whatever EG bundles) + the resources we set:
kubectl -n envoy-gateway-system get deploy \
  -l gateway.envoyproxy.io/owning-gateway-name=tuned \
  -o jsonpath='{.items[0].spec.template.spec.containers[?(@.name=="envoy")]}' \
  | jq '{image, resources}'

# Log level — verify via --log-level arg AND the admin /logging endpoint:
kubectl -n envoy-gateway-system get pod -l gateway.envoyproxy.io/owning-gateway-name=tuned \
  -o jsonpath='{.items[0].spec.containers[?(@.name=="envoy")].args}'

# Service inherited from GatewayClass default — still ClusterIP:
kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=tuned
```

`make diff` runs a quick side-by-side: `replicas`, resources, image
between this Gateway's deploy and example 01's baseline. The
override is the only diff.

## Inspecting the live config

```bash
make admin     # in another terminal — port-forward Envoy admin :19000
# Confirm the log level the process actually started with:
curl -s localhost:19000/logging
# Bootstrap config — generated by EG, includes admin, layered runtime, etc.
curl -s localhost:19000/config_dump?include_bootstrap | jq '.configs[0]'
```

## Common failure modes

| Symptom                                                                            | Cause                                                                                                  |
|------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| `Gateway` stays at `Programmed=False`, condition mentions `Invalid EnvoyProxy`     | `infrastructure.parametersRef.namespace` is set to something other than the Gateway's namespace, OR `name:` typo'd. Check `kubectl describe gateway tuned`. |
| Deployment looks unchanged after editing EnvoyProxy                                | EnvoyProxy edit takes a few seconds to propagate. Watch with `kubectl get pods -w -n envoy-gateway-system -l ...`. |
| Pods crashloop with `unable to bind port 8080`                                     | `container.securityContext` you set blocks Envoy's privileged bind. Default Envoy binds high ports — leave securityContext default unless you know you need it. |
| `Gateway` stays at `Programmed=False reason: AddressNotAssigned` on kind | Per-Gateway EnvoyProxy is missing `envoyService.type: ClusterIP`. Class default is NOT inherited (full replace). Add the field. |
| Adding `pod.tolerations` makes things schedulable, but other `pod.*` fields from the class default are gone | Same root cause: per-Gateway EnvoyProxy fully replaces the class default. Restate every field you want. |
| Bumping `replicas` works, but `resources` ignored                                  | `resources:` must be under `envoyDeployment.container:`, NOT `envoyDeployment:` directly. Easy typo. |
| `envoyService.type: LoadBalancer` set, but EXTERNAL-IP stuck at `<pending>`        | No LB controller in the cluster (kind has none). Either install one (MetalLB, etc.) or keep ClusterIP + port-forward. |
| Pinned `container.image: envoyproxy/envoy:vX.Y.Z` and data plane returns 500 / empty replies / crashloops | EG's generated bootstrap depends on extensions (Wasm runtime, contrib filters) that aren't in the vanilla upstream image. Use EG's bundled image variant (`distroless-vX.Y.Z` or an EG-compatible build), or — recommended — don't pin and let EG choose. |

## Exercises

1. **Tune the cluster default, not the per-Gateway.** Bump the
   `default-envoyproxy` in `envoy-gateway-system` to debug logging
   and watch every existing Gateway's pods restart. Roll it back
   afterwards — debug is expensive at scale.

2. **HPA.** Add `envoyHpa:` with min=2 max=8 + a CPU metric. Hit the
   `pf` endpoint hard with `hey` or `vegeta` and watch new replicas
   spin up. Caveat: with `replicas: 3` set, you may need to remove
   that field — HPA can't manage replicas that're forced.

3. **Pod anti-affinity.** Make the data plane pods spread across
   nodes via `topologySpreadConstraints`. Verify with
   `kubectl get pods -o wide` after scaling the kind cluster to
   2 worker nodes (see `00-kind-bootstrap/kind-config.yaml`).

4. **Prove the full-replace.** Set the GatewayClass default to
   include `pod.annotations: { team: platform }`. Then set this
   example's per-Gateway override to include
   `pod.annotations: { tier: prod }`. Which annotations do the data
   plane pods end up with? (Spoiler: only `tier: prod` — the entire
   class-default EnvoyProxy is dropped, not just the colliding
   field.)

5. **Per-component log level.** Restrict debug logging to just
   `http` and `connection` loggers, with the default at `warn`. Why
   would you do this in production? (Hint: noise, log volume cost.)

6. **Pin the Envoy image (carefully).** EG's bootstrap depends on
   extensions only the EG-bundled image variant ships. To pin
   safely, find the image EG is actually running today
   (`kubectl -n envoy-gateway-system get deploy
   -l gateway.envoyproxy.io/owning-gateway-name=eg
   -o jsonpath='{.items[0].spec.template.spec.containers[?(@.name=="envoy")].image}'`)
   and set `container.image:` to that exact value. Confirm with
   `kubectl get pods -w` that the rollout finishes. If you instead
   pin the vanilla `envoyproxy/envoy:vX.Y.Z`, you'll see the data
   plane crashloop (Wasm runtime missing) — that's the failure
   mode in the table above.

## Cleanup

```bash
make down
```

## What's next

- [`05-tls-termination`](../05-tls-termination/) — TLS at the
  Gateway. Mirrors Phase 1 example 09; introduces `cert-manager`
  as an optional sidebar.
