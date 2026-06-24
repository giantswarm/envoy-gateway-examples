# 09 — Backend (EG CRD): route to non-K8s targets

Up to here, every HTTPRoute we wrote pointed at a Kubernetes
`Service`. Envoy Gateway turned each Service ref into an Envoy
**EDS cluster** populated from the matching `EndpointSlice`.

The **`Backend`** CRD is Envoy Gateway's escape hatch for backends
that don't have a K8s Service:

- An external API (`example.com:80`)
- A static IP (a legacy host, a sidecar bind address)
- A Unix domain socket (a co-located process)
- An in-cluster name that DNS resolves but Service selectors don't
  reach (a CoreDNS stub zone, an out-of-cluster vault server with
  in-cluster DNS).

Same `HTTPRoute` shape — just a different `backendRefs[]` target.

This example wires up two Backends and routes a different path to
each:

- `/external/*` → Backend `example-com` (FQDN, external)
- `/internal/*` → Backend `helloworld-fqdn` (FQDN, in-cluster name)

By the end you should be able to answer:

- What does the `Backend` CR add that a `Service` backendRef can't?
- What kind of Envoy cluster does each `Backend` endpoint type
  produce (`fqdn` / `ip` / `unix`)?
- How does `Backend` interact with cross-namespace rules and
  `ReferenceGrant`?
- When SHOULDN'T you use `Backend`?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–08.
- The kind cluster must have **egress to the public internet** for
  the `/external` test. If your network blocks that, edit
  `backend-external.yaml` to point at any reachable host (your
  laptop's docker network, an internal mirror, etc.) and adjust
  the path/host in `httproute.yaml` accordingly.

## Run it

```bash
make up           # apply Namespace + 2 Backends + Gateway + HTTPRoute
make verify       # 6-step walkthrough proving each Backend works
make admin        # in another terminal — Envoy admin :19000
make down
```

## The `Backend` schema

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: my-backend
  namespace: my-ns
spec:
  # endpoints[] is a list — multiple endpoints become a multi-host
  # cluster (Envoy load-balances across them).
  endpoints:
    - fqdn:
        hostname: example.com
        port: 80
    - ip:
        address: 10.20.30.40
        port: 9443
    - unix:
        path: /var/run/upstream.sock

  # Optional protocol hints — equivalent of Service.appProtocol.
  # Use when you can't set appProtocol on a Service (e.g. external
  # backend has no Service at all).
  appProtocols:
    - kubernetes.io/h2c           # HTTP/2 cleartext, for gRPC etc.

  # Optional TLS to the upstream is configured separately, via a
  # BackendTLSPolicy attached to this Backend (example 10).
```

| endpoint type | Resulting Envoy cluster | Use case                                          |
|---------------|--------------------------|---------------------------------------------------|
| `fqdn:`       | `type: STRICT_DNS`       | Hostname Envoy re-resolves periodically           |
| `ip:`         | `type: STATIC`           | Hard-coded IP, no DNS resolution                  |
| `unix:`       | `type: STATIC` (pipe)    | Local sidecar / co-located process via UDS        |

## How HTTPRoute references a Backend

```yaml
backendRefs:
  - group: gateway.envoyproxy.io
    kind:  Backend
    name:  my-backend
    port:  80            # required by schema; EG ignores it for Backend refs
                         # (port comes from the Backend's endpoints[])
```

Two differences from a Service backendRef:

- The `group:` is the EG group, not the empty (core) group.
- The `port:` is required by the Gateway API schema for any
  backendRef, but EG ignores it here. Treat it as a placeholder —
  set it to something sensible (often matching the Backend's port)
  so it's not misleading.

## Backend + cross-namespace

`Backend` lives in a namespace. When an HTTPRoute references a
Backend in **another** namespace, the same `ReferenceGrant` rule
applies (example 08):

```yaml
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: <consumer-ns>
  to:
    - group: gateway.envoyproxy.io
      kind: Backend
      name: my-backend
```

In **this** example everything lives in `backend-demo`, so no RG is
needed. But interestingly the `helloworld-fqdn` Backend resolves a
name in the `demo` namespace's Service DNS — without a
`Service` backendRef, so no RG is needed there either. Backend with
FQDN is sometimes the simplest cross-namespace bridge.

## The pieces

```
manifests/
├── 00-namespace.yaml          # backend-demo
├── backend-external.yaml      # Backend -> example.com:80
├── backend-fqdn.yaml          # Backend -> helloworld.demo.svc.cluster.local:8080
├── gateway.yaml               # Gateway with HTTP listener
└── httproute.yaml             # 2 rules, URL-rewrite-stripping the prefix
```

The HTTPRoute also adds a `URLRewrite` filter with
`hostname: example.com` on the external rule. Without it, Envoy
forwards the original `Host: localhost:18100` header, and
example.com's web server will likely return a different / wrong
page. Setting `:authority` to `example.com` is what makes the
backend treat the request as belonging to that vhost.

## Common failure modes

| Symptom                                                                          | Cause                                                                                                                                |
|-----------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| Backend has no `Accepted` condition at all (status `conditions:` is empty)       | EG's Backend API is **off by default**. Needs `extensionApis.enableBackend: true` in the controller config. `make up` self-heals (helm upgrade --reuse-values + restart). Fresh bootstraps after this example was added already have it on. |
| Backend condition `Accepted=False reason: InvalidEndpoint`                       | `fqdn:` or `ip:` malformed. FQDN must be a valid DNS name; IP must be a literal address (not a hostname). Look at the Backend's status conditions. |
| `/external` 502s or curl times out                                                | No cluster egress to the internet, OR DNS for the hostname doesn't resolve in-cluster. Test inside the data plane pod: `kubectl exec -n envoy-gateway-system <envoy-pod> -- getent hosts example.com`. |
| `/external` reaches example.com but returns a weird page                          | The upstream sees `Host: localhost:18100` instead of `Host: example.com`. Set `urlRewrite.hostname: example.com` in the filter (already done in this example). |
| Cluster type shows `LOGICAL_DNS` not `STRICT_DNS`                                | Older EG version or `dns_lookup_family` setting that downgraded the cluster. STRICT_DNS resolves all A records; LOGICAL_DNS picks one. Functionality is similar; status field difference. |
| HTTPRoute `ResolvedRefs=False reason: BackendNotFound`                           | The `name:` in the backendRef typo'd, OR the Backend lives in a different namespace and you forgot the cross-ns RG.                  |

## Exercises

1. **IP-pinned Backend.** Replace `helloworld-fqdn` with an `ip:`
   endpoint pointing at the helloworld Service's ClusterIP
   (`kubectl -n demo get svc helloworld -o jsonpath='{.spec.clusterIP}'`).
   Confirm via `/config_dump` that the cluster type flipped to
   `STATIC`.

2. **Multi-endpoint Backend.** Add a second `fqdn:` endpoint to
   `helloworld-fqdn` (any hostname — the second endpoint is dead
   weight). Envoy now load-balances between the two. Check the
   cluster's `endpoints[]` list.

3. **HTTPS upstream.** Add a `BackendTLSPolicy` (preview of
   example 10) that targets `Backend/example-com`, enabling TLS to
   port 443. Then change the Backend's `port:` to 443 and watch
   the same `curl /external` succeed over HTTPS.

4. **Unix socket.** Add an `EnvoyProxy` override that creates a
   sidecar container in the data-plane pod listening on a UDS.
   Reference that UDS from a Backend. (Complex; this is where
   `Backend.unix:` shines — sidecar-pattern integration.)

5. **No-RG cross-namespace.** Move the HTTPRoute to a new
   namespace, set `parentRefs[].namespace: backend-demo` (with
   `allowedRoutes.namespaces.from: All` on the listener), and keep
   the Backend in `backend-demo`. Show that the Backend ref still
   works without a ReferenceGrant — it's cross-namespace because
   of the Gateway, not the Backend.

## Cleanup

```bash
make down
```

## What's next

- [`10-backendtlspolicy`](../10-backendtlspolicy/) — TLS from Envoy
  to the upstream (mTLS, custom CAs). Pairs naturally with
  `Backend` since external targets often demand HTTPS.
