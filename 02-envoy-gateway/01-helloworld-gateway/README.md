# 01 — Hello World via Gateway API

The Phase 2 equivalent of [Phase 1 example 01](../../01-envoy-proxy/01-helloworld-static/).
Same goal — get a single request through Envoy to the helloworld
backend — but now the configuration is **two Gateway API CRs** that
Envoy Gateway translates into the underlying `envoy.yaml`.

By the end of this example you should be able to answer:

- What does the `GatewayClass / Gateway / HTTPRoute` triplet do?
- What's `parentRefs`, `backendRefs`, `allowedRoutes`?
- Where does Envoy Gateway create the data plane, and how do I find it?
- What does the Phase 1 `envoy.yaml` look like when expressed as
  Gateway API CRs?

## Prerequisites

- The shared cluster from [`../00-kind-bootstrap/`](../00-kind-bootstrap/)
  is up. (`make up` in that directory if not.)
- `kubectl`, `curl`, `jq`.

## Run it

```bash
make up           # apply Gateway + HTTPRoute, wait for them to be Programmed/Accepted
make verify       # exercise the data plane + dump the generated Envoy config
make down         # delete only this example's manifests (the cluster stays up)
```

`make up` is a no-op if the cluster isn't ready — it `kubectl get`s the
`eg` GatewayClass and `svc/helloworld` first, with a clear error if
either is missing.

## What we apply

Two manifests, both in the `demo` namespace alongside the helloworld
backend:

### `gateway.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: demo
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
```

- **`gatewayClassName: eg`** points at the GatewayClass Envoy Gateway
  auto-installed when its helm chart ran. Verify with
  `kubectl get gatewayclass eg`. A GatewayClass is roughly "which
  controller will manage Gateways that name this class".
- **`listeners[]`** is the bind list — what Envoy will accept. Each
  listener has `protocol` (HTTP / HTTPS / TLS / TCP / UDP) and `port`.
  Phase 1's `listener_http -> address.socket_address.port_value: 10000`
  is the same idea.
- **`allowedRoutes.namespaces.from: Same`** scopes which HTTPRoutes
  may attach. `Same` keeps things in `demo`; `All` opens to every
  namespace; `Selector` accepts a label match.

### `httproute.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: helloworld
  namespace: demo
spec:
  parentRefs:
    - name: eg
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: helloworld
          port: 8080
```

- **`parentRefs`** is which Gateway(s) we attach to. Same HTTPRoute can
  attach to multiple Gateways (public + internal, for example).
- **`rules[]`** is the route table. Each rule has `matches[]` (OR-ed)
  and `backendRefs[]` (weighted load balancing across them).
- **`matches[].path.type`** is one of `PathPrefix`, `Exact`,
  `RegularExpression`. We use `PathPrefix /` — the catch-all,
  equivalent to Phase 1's `match: { prefix: "/" }`.
- **`backendRefs[]`** lists target Services in the same namespace
  (cross-namespace needs a `ReferenceGrant` — example 08).

## Where Envoy actually runs

When you apply the Gateway, Envoy Gateway notices and creates a
data-plane Deployment + Service in the `envoy-gateway-system`
namespace. The pods and services carry labels that let you find them:

```bash
kubectl -n envoy-gateway-system get pods,svc \
  -l gateway.envoyproxy.io/owning-gateway-name=eg
```

The Service is `ClusterIP` by default — no external IP. We reach it
via `kubectl port-forward` (the `make pf` helper does this). In
production you'd give the Gateway a LoadBalancer or expose it through
your cloud provider's controller; example 04 (the EnvoyProxy CR)
covers customizing that.

## Status conditions

Both resources expose a `status:` with conditions that tell you
whether Envoy Gateway accepted them:

| Resource    | Condition       | What True means                                     |
|-------------|-----------------|-----------------------------------------------------|
| Gateway     | `Accepted`      | Envoy Gateway recognised this Gateway and will manage it. |
| Gateway     | `Programmed`    | Data plane Deployment + Service are up.            |
| HTTPRoute   | `Accepted`      | The Gateway accepted the route attachment.          |
| HTTPRoute   | `ResolvedRefs`  | All `backendRefs` point at real Services.          |

`make up` waits for `Programmed=True` on the Gateway and `Accepted=True`
on the HTTPRoute before returning. `make status` prints the full
condition list.

A `ResolvedRefs=False` is the most common first-time failure —
typo in `backendRefs.name` or wrong port. The condition message tells
you exactly what was missing.

## Verify

`make verify` walks five checkpoints:

1. Check all three conditions above.
2. Locate the auto-generated Service + Pod by label.
3. Port-forward the Service to `localhost:8080`, send 10 requests,
   show the distribution across the 3 helloworld replicas (`from_`
   field in each response).
4. Port-forward the Envoy admin endpoint and pull out the dynamic
   **listener**, **route**, and **cluster** sections of `/config_dump`.
   Saves the full dump to `envoy-config.expected.json`.
5. Print a Phase 1 ↔ Phase 2 mapping table.

The mapping table is the point of this whole example:

```
Phase 1 envoy.yaml             Phase 2 CR
---------------------------    ------------------------------------
listeners[].name               Gateway.metadata.name + listener
listeners[].address.port_value Gateway.spec.listeners[].port
filter_chains.filters HCM      auto-generated by EG
route_config.virtual_hosts[]   HTTPRoute.spec.hostnames + parentRefs
routes[].match.prefix          HTTPRoute.spec.rules[].matches[].path
routes[].route.cluster         HTTPRoute.spec.rules[].backendRefs (->EDS cluster)
clusters[]                     Service + EndpointSlice in the demo ns
type: STRICT_DNS               type: EDS (xDS-driven)
```

Two key differences:

- **EDS instead of STRICT_DNS.** Envoy Gateway delivers endpoints to
  Envoy via xDS, not via Envoy doing its own DNS lookup. That's why
  the cluster type changes — it's the same load-balancing pool, just
  populated dynamically.
- **The HCM is implicit.** Phase 1 made you spell out
  `http_connection_manager` + `router` filter. Envoy Gateway adds
  these for you on any HTTP/HTTPS listener; you don't see them in the
  CR YAML, but they're right there in `/config_dump`.

## Inspect the live config interactively

`make admin` port-forwards the Envoy admin port. In another terminal:

```bash
curl -s localhost:19000/config_dump | jq | less
curl -s localhost:19000/clusters
curl -s localhost:19000/listeners
curl -s 'localhost:19000/stats?filter=ingress_http' | head
```

Everything you learned in [Phase 1 example 02](../../01-envoy-proxy/02-config-anatomy/)
applies — Envoy doesn't care that the config came from CRs.

If you have `egctl` installed (`go install
github.com/envoyproxy/gateway/cmd/egctl@latest`), it's a friendlier
front-end:

```bash
egctl config envoy-proxy all -n envoy-gateway-system
egctl config envoy-proxy listener -n envoy-gateway-system
egctl config envoy-proxy route -n envoy-gateway-system
egctl config envoy-proxy cluster -n envoy-gateway-system
```

## Common failure modes

| Symptom                                                | Cause                                                |
|--------------------------------------------------------|------------------------------------------------------|
| `Gateway/eg` stays Programmed=False                    | EG controller crashlooping. `kubectl -n envoy-gateway-system logs deploy/envoy-gateway`. |
| `HTTPRoute` shows `ResolvedRefs=False`                 | Wrong `backendRefs.name` or port. Check `kubectl get svc -n demo`. |
| 503 from curl                                          | Listener up but no upstream endpoints — usually a Service selector mismatch. Run `kubectl get endpoints -n demo helloworld`. |
| Port-forward exits with "Address already in use"       | Another example's `kubectl port-forward` is still alive. `lsof -i :8080`. |
| `Gateway/eg` Accepted=False with message about `gatewayClassName` | Typo, or you haven't installed EG. Confirm with `kubectl get gatewayclass eg`. |

## Exercises

1. **Add a second listener.** Append an `https` listener (TLS comes in
   example 05 — for now just a second HTTP listener on port 8080 named
   `http2`). What new resources does EG create? Hint: `make admin`
   and look at `listeners`.

2. **Attach a route from a different namespace.** Set
   `allowedRoutes.namespaces.from: All`, then `kubectl apply` an
   HTTPRoute in a fresh namespace pointing at this Gateway. Without
   the change to `All` the route is rejected — what does the status
   condition say?

3. **Exact path matching.** Change the HTTPRoute's `matches[].path` to
   `type: Exact, value: /`. Try `curl -i .../foo` — what happens? Look
   at the generated Envoy route table.

4. **Two backendRefs with weights.** Stand up a `helloworld-v2`
   Service (you can fake it with the same Deployment but a different
   `NAME` env), then split traffic 80/20 across them via two
   `backendRefs` with `weight: 80` and `weight: 20`.

5. **Find the EDS cluster name.** Inspect the generated `/config_dump`
   and identify the cluster name format EG uses. It encodes the
   namespace + Service. (You'll need this naming convention later
   when policies attach to specific backends.)

## Cleanup

```bash
make down     # delete Gateway + HTTPRoute. Cluster + helloworld stay up.
```

## What's next

- `02-egctl-and-config-dump` — proper deep-dive on reading the
  generated Envoy config and the xDS state machine.
- `03-httproute-matching-and-filters` — Phase 2's equivalent of
  [Phase 1 example 03](../../01-envoy-proxy/03-routing-basics/).
