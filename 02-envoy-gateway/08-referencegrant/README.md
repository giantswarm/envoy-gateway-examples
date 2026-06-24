# 08 — ReferenceGrant

By default, Gateway API forbids cross-namespace references. An
HTTPRoute in namespace `apps` can't point at a Service in `demo`,
and a Gateway in `apps` can't load a TLS Secret out of `demo` —
unless the *target namespace* explicitly grants the access via a
`ReferenceGrant`. That's the whole security model: the resource
being read is in control, not the one trying to read it.

We exercise **both** kinds of cross-namespace edge in one example:

- Gateway in `apps` → `Secret/apps-tls` in `demo` (the HTTPS cert).
- HTTPRoute in `apps` → `Service/helloworld` in `demo` (the
  backend).

Each edge gets its own ReferenceGrant in `demo`. `verify.sh`
demonstrates the dynamic effect: delete a grant, watch the
condition flip to `ResolvedRefs=False reason: RefNotPermitted`,
re-apply, watch recovery.

By the end of this example you should be able to answer:

- What's a ReferenceGrant, where does it live, and what does it
  control?
- Which Gateway API references **need** one? Which references
  *don't* (and what mechanism gates those instead)?
- How does the `from:` / `to:` shape work — what does narrow vs
  broad look like?
- What's the difference between Gateway listener attachment
  (`allowedRoutes.namespaces`) and ReferenceGrant?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–07.
- `openssl` on your `$PATH`.

## Run it

```bash
make up           # gen-certs.sh, then apply RGs + Gateway + HTTPRoute
make verify       # 6 sections incl. live "delete-RG-and-recover" flip
make admin        # in another terminal — Envoy admin :19000
make down
```

## The mental model

```
namespace "apps"                    namespace "demo"
─────────────────                   ─────────────────
                                    Secret/apps-tls
                                    (TLS cert + key)
Gateway/crossns  ─── certificateRefs ──┘
   listener https                   ▲
                                    │
                                    ReferenceGrant
                                    "gateway-to-tls-secrets"
                                       from: Gateway from apps
                                       to:   Secret name apps-tls

HTTPRoute/app    ─── backendRefs ──── Service/helloworld
                                    ▲
                                    ReferenceGrant
                                    "httproute-to-services"
                                       from: HTTPRoute from apps
                                       to:   Service name helloworld
```

Both grants are in **the target namespace** (`demo`). That's the
counter-intuitive bit: the namespace whose resource you want to
*expose* is the one that creates the RG.

## What `ReferenceGrant.spec` says

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: gateway-to-tls-secrets
  namespace: demo                  # LIVES in the target namespace
spec:
  from:
    - group: gateway.networking.k8s.io
      kind:  Gateway               # the kind that's READING
      namespace: apps              # the namespace it's reading FROM
  to:
    - group: ""                    # core API
      kind:  Secret                # the kind that's BEING READ
      name:  apps-tls              # optional — omit for "any in this ns"
```

A few rules:

- `from[]` is a list of (group, kind, namespace) tuples. ALL must
  match for the grant to apply — no globbing, no labels.
- `to[]` is the *target* — what's being exposed. `name:` is
  optional: omit to grant access to every resource of that kind in
  the namespace; set it to lock the grant down to one object.
- One ReferenceGrant per *(kind on the from side, kind on the to
  side)* tuple is the typical shape. If you mix multiple from-kinds
  in one grant, it gets confusing.

## Which references need a ReferenceGrant?

| Gateway API reference                                                          | Cross-ns allowed? | Mechanism                                                                                                  |
|---------------------------------------------------------------------------------|--------------------|------------------------------------------------------------------------------------------------------------|
| HTTPRoute / GRPCRoute / TCPRoute / UDPRoute / TLSRoute → `backendRefs[]`        | Yes               | **ReferenceGrant** in the backend's namespace                                                              |
| Gateway listener `tls.certificateRefs[]` → Secret                              | Yes               | **ReferenceGrant** in the Secret's namespace                                                               |
| Gateway listener `tls.frontendValidation.caCertificateRefs[]` → ConfigMap (mTLS)| Yes               | **ReferenceGrant** (kind ConfigMap)                                                                        |
| BackendTLSPolicy `caCertificateRefs[]` → ConfigMap (upstream trust, ex 10)     | Yes               | **ReferenceGrant** (kind ConfigMap)                                                                        |
| HTTPRoute `parentRefs[]` → Gateway in another namespace                        | Yes               | NOT a ReferenceGrant. Controlled by `Gateway.spec.listeners[].allowedRoutes.namespaces.{from,selector}` on the **Gateway** side. |
| `Gateway.spec.infrastructure.parametersRef` → EnvoyProxy (example 04)         | No                | Must be in the same namespace as the Gateway.                                                              |
| `GatewayClass.spec.parametersRef` → EnvoyProxy                                | Any ns            | Namespace is explicit on the parametersRef itself; no grant needed (cluster-scoped object).                |

Two distinct mechanisms gate cross-namespace edges:

- **ReferenceGrant** — "I, the target, allow you to read me." Used
  for *what's behind the edge* (Secret, ConfigMap, Service).
- **`allowedRoutes.namespaces`** on a Gateway listener — "I, the
  Gateway, allow you to attach routes to me." Used for *Gateway
  attachment*.

Both protect the receiving party, but at different scopes.

## The pieces

```
manifests/
├── 00-namespace.yaml       # creates `apps`
├── gateway.yaml            # Gateway in apps; certRef -> demo/apps-tls
├── httproute.yaml          # HTTPRoute in apps; backendRef -> demo/helloworld
├── refgrant-secret.yaml    # In `demo`: Gateway from apps may read Secret apps-tls
└── refgrant-service.yaml   # In `demo`: HTTPRoute from apps may read Service helloworld
```

`make up` also creates `Secret/apps-tls` in `demo` from
`gen-certs.sh` output (we don't commit certs; the file is
gitignored).

## Verify

`make verify` walks through:

1. List the two ReferenceGrants in `demo`.
2. Gateway `Programmed=True`, listener `ResolvedRefs=True` (cert
   reachable), HTTPRoute `ResolvedRefs=True` (backend reachable).
3. Drive HTTPS through the cross-ns Gateway → backend round-trip.
4. **Live flip**: delete `httproute-to-services` RG; wait for
   `ResolvedRefs=False reason: RefNotPermitted`; confirm data
   plane returns non-2xx.
5. Re-apply the RG; wait for `ResolvedRefs=True`; confirm 200s
   return.
6. Mapping table — what needs an RG, what doesn't.

## Common failure modes

| Symptom                                                                              | Cause                                                                                                                  |
|---------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| `ResolvedRefs=False reason: RefNotPermitted message: ...`                            | Missing RG, OR the RG's `from`/`to` doesn't match exactly (kind/group/namespace/name). Check group "" for Secret/Service. |
| RG created in the SOURCE namespace (the consumer's ns) — nothing changes              | RG must live in the TARGET namespace. Easiest mistake to make.                                                          |
| `from.kind: httproute` (lowercase) — RG appears to be ignored                         | Kind is case-sensitive: `HTTPRoute`. Plurals don't work either.                                                         |
| RG matches on kind+namespace but `name:` doesn't match — still rejected               | `to.name` is optional, but if set it must match exactly. Drop it to allow all.                                          |
| HTTPRoute can't attach to a Gateway in another namespace                              | This is a different gate: `Gateway.spec.listeners[].allowedRoutes.namespaces.from`. RG doesn't apply to parent attachment. |
| Multiple `from[]` entries — one matches, another doesn't                              | EG honors any matching entry. Add more `from[]` entries to broaden; don't try to express AND.                          |

## Exercises

1. **Lock down to a name.** Add `name: helloworld` to the
   `refgrant-service.yaml` (already there). Now create a second
   Service in `demo` called `other` and add a second HTTPRoute that
   references it. What does the condition say? Adjust the RG to
   permit both.

2. **Multi-namespace fan-in.** Create `apps-blue` and `apps-green`,
   each with its own HTTPRoute that backendRefs `demo/helloworld`.
   Write a single RG that permits both. (Hint: two `from[]`
   entries.)

3. **Drop the cert.** Delete `refgrant-secret.yaml`. Watch the
   *listener* condition (not the HTTPRoute condition) flip to
   `ResolvedRefs=False reason: InvalidCertificateRef`. What does
   `make verify` traffic look like with the listener still down?

4. **Mixed kinds in one RG.** Try a single RG with both `from`
   kinds (Gateway AND HTTPRoute). Does EG accept it? Read EG's
   logs (`make logs`) to see how it's parsed.

5. **Compare with allowedRoutes.** Move the HTTPRoute to `apps-v2`,
   keep the Gateway in `apps`. Without changing anything else,
   what condition do you see — RG missing, or attachment denied?
   Why?

## Cleanup

```bash
make down
make clean-certs
```

## What's next

- [`09-backend-resource`](../09-backend-resource/) — the `Backend`
  CRD. Route to non-K8s targets (FQDN, static IP) without standing
  up a Service.
