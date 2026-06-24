# 06 — GRPCRoute

Gateway API's `GRPCRoute` is the sibling of `HTTPRoute` for gRPC.
Same Gateway, same listener (plain HTTP — gRPC just needs HTTP/2 on
the wire, which Envoy turns on automatically), different route kind.

We deploy [`moul/grpcbin`](https://github.com/moul/grpcbin) — a
small gRPC reference server with reflection — and route to it via a
`GRPCRoute` with four rules that show service-level, method-level,
and catch-all matching plus a per-rule header injection.

By the end of this example you should be able to answer:

- What's the difference between `GRPCRoute` and `HTTPRoute`?
- What's the matching grammar — by what fields does Gateway API
  let me route a gRPC call?
- How does Envoy actually route gRPC under the hood — what shape
  does the generated config take?
- Why does the cluster pick HTTP/2 automatically? Where does that
  signal come from?
- What can `GRPCRoute.filters[]` do, and what's missing compared to
  `HTTPRoute.filters[]`?

> **Phase 1 comparison**: Phase 1 example 19 (`grpc-and-grpc-web`)
> was deferred at the user's request, so this example stands alone.
> The mapping section still shows the equivalent Envoy
> configuration EG generates.

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–05 (we reuse the GatewayClass, kind cluster,
  port-forward pattern).
- `grpcurl` on your `$PATH`. (`brew install grpcurl`, or
  `go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest`).

## Run it

```bash
make up           # apply grpcbin + Gateway + GRPCRoute, wait for Programmed/Accepted
make verify       # 8-step grpcurl-driven walkthrough + generated-config dump
make admin        # in another terminal — port-forward Envoy admin :19000
make down
```

## The matching grammar

```yaml
rules:
  - matches:
      - method:
          type: Exact | RegularExpression    # default Exact
          service: foo.bar.MyService          # fully-qualified, with package
          method:  MyMethod                   # OPTIONAL — omit to match all methods
        headers:
          - { name, type: Exact|RegularExpression, value }
    filters: [...]
    backendRefs: [...]
```

What this gives you:

- **Service-level match**: just set `method.service:` — every method
  on that service routes via this rule.
- **Method-level match**: set both `service:` and `method:` — only
  that one RPC routes here.
- **No prefix matching**: gRPC paths are tuples, not paths. There's
  no equivalent to HTTPRoute's `PathPrefix`.
- **Header matches**: same shape as HTTPRoute. gRPC metadata appears
  as HTTP/2 headers on the wire, so the matcher is the same.

The `GRPCRoute` in this example exercises three shapes:

| Rule | `method` filter                                    | What it matches                            |
|------|-----------------------------------------------------|--------------------------------------------|
| 1    | `service: hello.HelloService`                      | every method on `hello.HelloService`       |
| 2    | `service: grpcbin.GRPCBin, method: DummyUnary`     | only `grpcbin.GRPCBin/DummyUnary`          |
| 3    | `service: grpcbin.GRPCBin` (no `method:`)          | every other method on `grpcbin.GRPCBin`    |
| 4    | `service: grpc.reflection.v1alpha.ServerReflection`| reflection — needed for `grpcurl list`    |

Rule precedence inside one `GRPCRoute` is by specificity (same as
HTTPRoute): the rule with both `service` AND `method` wins over the
service-only one. So `DummyUnary` requests hit Rule 2 even though
Rule 3 would also match.

## Filters available on `GRPCRoute`

| Filter type             | What it does                                                |
|-------------------------|-------------------------------------------------------------|
| `RequestHeaderModifier` | add / set / remove HTTP/2 headers (gRPC metadata)            |
| `ResponseHeaderModifier`| same, on response                                            |
| `RequestMirror`         | tee the RPC to a second backend (fire-and-forget)            |
| `ExtensionRef`          | attach an `HTTPRouteFilter`-style extension                  |

Things `GRPCRoute` doesn't have:

- **No URLRewrite / RequestRedirect**: gRPC paths are
  `/<package.Service>/<Method>` and aren't meant to be rewritten.
  Talk to the upstream's own routing if you need that.
- **No method match list per matcher**: each `matches[]` entry has
  one `method:`. For multiple, use multiple `matches[]` entries (OR).

## Why HTTP/2 just works

gRPC requires HTTP/2 end-to-end. EG turns it on automatically:

- **Downstream** (client → Envoy): EG sees a `GRPCRoute` attached
  and enables `http2_protocol_options` on the listener's HCM.
- **Upstream** (Envoy → backend): EG reads the Service's
  `appProtocol:` field. We set `appProtocol: kubernetes.io/h2c` on
  the `grpc` port of `Service/grpcbin`, so EG generates the cluster
  with HTTP/2.

Without that `appProtocol`, Envoy would try HTTP/1.1 to the
backend, which gRPC servers refuse — you'd see
`HTTP/2 over cleartext was not enabled` or similar in the logs.
`appProtocol` is the clean signal; an alternative is a
`BackendTLSPolicy` for HTTP/2-over-TLS (covered in example 10).

## How a single RPC flows through

```
   grpcurl                       Envoy (data plane)                       grpcbin pod
   --------                      ------------------                       -----------
   HTTP/2 POST                   listener :80
   :path /hello.HelloService/    ├── HCM (http2_protocol_options)
        SayHello                 ├── route table:
   :method POST                  │   - match: header[:path] = /hello.HelloService/.*
   metadata...                   │     route -> cluster grpcbin-9000
                                 └── cluster: HTTP/2, EDS endpoints
                                                                    HTTP/2 POST
                                                                    /hello.HelloService/SayHello
                                                                    -> RPC handler -> response
                                 <- HTTP/2 response back, framed as gRPC
   gRPC reply { message: "..." }
   trailers: grpc-status 0
```

`/config_dump` shows exactly this: the GRPCRoute rules materialize
as Envoy `routes[]` with `match.headers[:path]` patterns.

## The pieces

`manifests/grpcbin.yaml` — Namespace `grpc-demo`, Deployment +
Service for `moul/grpcbin:latest`. Service exposes 9000 (gRPC) with
`appProtocol: kubernetes.io/h2c`. Pinned to `latest` because the
project only publishes `latest` + git-SHA tags — same caveat as
Phase 1 ex 11's `envoyproxy/ratelimit:master`.

`manifests/gateway.yaml` — Gateway `rpc` with one HTTP listener.
`allowedRoutes.kinds: [{kind: GRPCRoute}]` restricts attachment to
gRPC routes only — a nice safety rail for "gRPC-only" Gateways.

`manifests/grpcroute.yaml` — the four rules above.

## Verify

```bash
make verify
```

8 sections:

1. Gateway Programmed + GRPCRoute Accepted/ResolvedRefs.
2. Port-forward `localhost:18090 → svc/<rpc> :80`.
3. `grpcurl list` — proves reflection routing works (Rule 4).
4. Rule 1 — `SayHello` (unary) + `LotsOfReplies` (server streaming).
5. Rule 2 — `DummyUnary` with the header-injection filter.
6. Rule 3 — `Empty` + `SpecificError` (controlled gRPC status code).
7. Dump `/config_dump`: HCM http2 options, route header-matches,
   cluster HTTP/2 settings.
8. GRPCRoute ↔ Envoy mapping table.

## Common failure modes

| Symptom                                                                | Cause                                                                                                       |
|-------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| `grpcurl list` → `Error invoking method... INTERNAL: ...`              | Reflection rule (4) missing or wrong service path. Default reflection service is `grpc.reflection.v1alpha.ServerReflection`. |
| `rpc error: code = Unknown desc = HTTP status 426`                     | Upstream got HTTP/1.1 instead of HTTP/2. Service is missing `appProtocol: kubernetes.io/h2c`.               |
| `code = Unimplemented desc = unknown service ...`                      | The Gateway *did* route, but to a backend that doesn't host that service — check the backendRef Service points at grpcbin. |
| `GRPCRoute Accepted=False reason: UnsupportedValue`                    | A GRPCRoute pointing at a listener whose `allowedRoutes.kinds` doesn't include `GRPCRoute`, or a typo in `kind:`. |
| GRPCRoute `ResolvedRefs=False, PortNotFound`                            | `backendRefs[].port` doesn't exist on the Service. Use the **Service port** (9000 here), not the container port. |
| Calls work but RPC tagged with `x-eg-tagged` header not visible       | grpcbin's DummyUnary doesn't echo request headers in its response. Confirm via the access log on the Envoy admin port (`/stats?usedonly` includes header counters). |

## Exercises

1. **Tighten Rule 2.** Add a header match
   (`headers: - { name: x-tenant, type: Exact, value: gold }`) so
   only "gold" tenants hit `DummyUnary`. Without that header, the
   request should fall through to Rule 3. Verify with `grpcurl -H`.

2. **Mirror.** Add a `RequestMirror` filter on Rule 1 that mirrors
   to a second `grpcbin` deployment in a different namespace. Use
   a `ReferenceGrant` (preview of example 08).

3. **Per-RPC override.** Add a fifth rule that matches
   `grpcbin.GRPCBin/RandomError` and points at a **different**
   backend (e.g. a Service alias of the same grpcbin pod). Show via
   `/config_dump` that two clusters now exist.

4. **HTTPS gRPC.** Combine with example 05: change the Gateway
   listener to `HTTPS` with a `hello.local` cert, drive traffic with
   `grpcurl -cacert certs/ca.crt -authority hello.local
   localhost:18443`. Confirm Envoy negotiates ALPN `h2`.

5. **HTTPRoute on the same Gateway.** Remove
   `allowedRoutes.kinds:` from the listener and attach an HTTPRoute
   pointing at `/grpc.reflection.v1alpha.ServerReflection/`. Why
   does this break gRPC clients? (Hint: HCM behavior + content-type.)

## Cleanup

```bash
make down
```

## What's next

- [`07-tcproute-udproute-tlsroute`](../07-tcproute-udproute-tlsroute/)
  — the non-HTTP route kinds. Plain TCP, UDP, and SNI-routed TLS
  passthrough.
