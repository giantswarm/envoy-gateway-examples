# 22 — XListenerSet: multi-tenant Gateway sharing

> **⚠️ Heads-up — EG runtime support is still landing**
>
> The CR shape, the multi-tenant pattern, and the route attachment
> via `parentRefs[].kind: XListenerSet` are all valid Gateway API
> experimental channel, BUT Envoy Gateway itself doesn't yet
> translate `XListenerSet` into actual Envoy listeners as of EG
> **v1.5.0** (what the bootstrap installs). The CRs are accepted,
> conditions stay at `Accepted=Unknown reason: Pending message:
> "Waiting for controller"`, and the auto-generated data-plane
> Service has only the base Gateway's port — not the contributed
> ones.
>
> Read this example as **documentation of what XListenerSet will
> look like in your manifests**, plus a working multi-tenant
> backend / HTTPRoute layout you can adopt today against separate
> Gateways. Once EG ships full translation, `make verify` should
> succeed against the same manifests with no edits.
>
> Try bumping `EG_HELM_VERSION` in `../00-kind-bootstrap/Makefile`
> to the latest release before you give up — this README will be
> behind by the time someone reads it.

The headline Gateway API experimental feature. Solves the classic
org-design problem:

> The platform team owns the Gateway resource (security, certs,
> infra). Multiple tenant teams want to add their own listeners
> (ports, hostnames, TLS configs) without filing tickets against
> the Gateway resource.

`XListenerSet` lets each tenant team contribute listeners to a
shared base Gateway from their OWN namespace, using their OWN RBAC.
One Envoy data plane, multiple owners.

This example:

```
namespace platform           namespace team-blue          namespace team-green
─────────────────            ─────────────────            ──────────────────
Gateway "shared"             XListenerSet "blue"          XListenerSet "green"
  - listener "base" :80        - listener blue-http :8080   - listener green-http :8081
  - allowedListeners.          - parentRef -> shared        - parentRef -> shared
    namespaces.from: All       HTTPRoute "blue"             HTTPRoute "green"
                                 - parentRef XListenerSet     - parentRef XListenerSet
                               blue-backend (nginx)         green-backend (nginx)
```

By the end you should be able to answer:

- What does XListenerSet contribute to a base Gateway?
- What's the difference between `allowedListeners.namespaces` and
  `allowedRoutes.namespaces`?
- How do routes attach to a listener that lives in an XListenerSet?
- What does the generated Envoy config look like — one listener
  per XListenerSet, or merged?
- When SHOULDN'T you use XListenerSet?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–21.
- The bootstrap installs the **experimental** Gateway API channel
  (`xlistenersets.gateway.networking.x-k8s.io`) — and **EG v1.5+**.
  Earlier EG (≤ 1.4) has the CRD but doesn't watch the resource —
  XListenerSets sit at `Waiting for controller` forever.
  `make check-cluster` verifies the CRD is present.

## Run it

```bash
make up           # 3 namespaces + 2 backends + Gateway + 2 XListenerSets + 2 HTTPRoutes
make verify       # 6-section walkthrough
make pf-blue      # in another terminal — hit team-blue's listener
make down
```

## The `allowedListeners` field

```yaml
spec:                                # on the Gateway
  allowedListeners:
    namespaces:
      from: All | Same | Selector    # who can attach an XListenerSet?
      selector:
        matchLabels:
          tenant: gold
```

Counterpart to `allowedRoutes.namespaces` (which controls who can
attach an HTTPRoute), but for XListenerSet attachment. The Gateway
owner uses it to limit which tenants can contribute listeners.

This is gated **by the Gateway** (the resource being consumed) —
not by a `ReferenceGrant` (see example 08 for the distinction).

Available since Gateway API v1.3 (the bootstrap installs that or
newer; XListenerSet itself requires EG v1.5+).

## XListenerSet shape

```yaml
apiVersion: gateway.networking.x-k8s.io/v1alpha1
kind: XListenerSet
metadata:
  name: blue
  namespace: team-blue
spec:
  parentRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: shared
    namespace: platform              # cross-ns — needs `allowedListeners` on Gateway
  listeners:
    - name: blue-http
      port: 8080
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same                 # routes from team-blue only
```

- The `listeners:` array is the same shape as `Gateway.spec.listeners[]`
  — same fields (name, port, protocol, hostname, tls, allowedRoutes).
- **Listener names must be globally unique** across the base Gateway
  AND every attached XListenerSet. Collision flips the offender to
  `Conflicted=True`.
- Each XListenerSet's listener has its own `allowedRoutes` —
  tenants can independently decide who attaches routes to their
  listener.

## How HTTPRoutes attach

Two equivalent options:

```yaml
# Option A: parentRef the XListenerSet directly
parentRefs:
  - group: gateway.networking.x-k8s.io
    kind: XListenerSet
    name: blue

# Option B: parentRef the base Gateway with sectionName
parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: shared
    namespace: platform
    sectionName: blue-http
```

This example uses **Option A** — it makes team ownership
self-evident from the route's YAML alone. Option B works the same
but mixes the team's HTTPRoute with a reference into the
platform's namespace.

## One data plane, many listeners

The base Gateway always provisions ONE `Deployment` + ONE `Service`
in `envoy-gateway-system`. XListenerSets ADD ports to that same
Service and ADD listeners to that same Envoy. They do NOT create
new pods.

```
$ kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=shared
NAME              TYPE        PORT(S)
envoy-platform-…  ClusterIP   80/TCP, 8080/TCP, 8081/TCP
```

That's the cost-and-isolation trade-off: cheaper (one pod per
gateway, not per team) but tenants share the Envoy process. For
strict isolation, give each team its own Gateway.

## Listener-level status

The base Gateway's `status.listeners[]` lists ALL listeners — its
own AND every attached XListenerSet's. Each has its own conditions
and `attachedRoutes` count:

```
$ kubectl -n platform get gateway shared \
    -o jsonpath='{range .status.listeners[*]}{.name}: attachedRoutes={.attachedRoutes}{"\n"}{end}'
base:        attachedRoutes=0
blue-http:   attachedRoutes=1
green-http:  attachedRoutes=1
```

This is the fastest way to see whether a team's listener is
accepting traffic.

## The pieces

```
manifests/
├── 00-namespaces.yaml      # platform, team-blue, team-green
├── gateway.yaml             # base Gateway (with allowedListeners)
├── blue-backend.yaml        # nginx in team-blue returning {"team":"blue"}
├── green-backend.yaml       # nginx in team-green returning {"team":"green"}
├── listenerset-blue.yaml    # XListenerSet adds blue-http :8080
├── listenerset-green.yaml   # XListenerSet adds green-http :8081
├── httproute-blue.yaml      # parentRef -> XListenerSet/blue
└── httproute-green.yaml     # parentRef -> XListenerSet/green
```

## Verify

`make verify` walks through 6 sections:

1. Gateway Programmed, both XListenerSets Accepted, both HTTPRoutes
   Accepted; plus the listener-level view.
2. Find the single data-plane Service and inspect its ports
   (should show 3: 80, 8080, 8081).
3. Port-forward all three ports.
4. Hit each — base returns 404 (no route attached), blue returns
   `{"team":"blue",...}`, green returns `{"team":"green",...}`.
5. `/config_dump` shows three listeners on the SAME Envoy pod, with
   one route_config per listener.
6. Mapping table.

## Common failure modes

| Symptom                                                                | Cause                                                                                                          |
|-------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| XListenerSet stuck on conditions `Accepted=Unknown reason: Pending message: Waiting for controller` (since 1970) | EG controller doesn't watch the resource. Upgrade EG to v1.5+ via `cd ../00-kind-bootstrap && make up` (helm bumps the chart version in place). |
| `unknown field "spec.allowedListeners"` when applying the Gateway        | Gateway API < v1.3 in the cluster. Bootstrap installs v1.3 by default; re-run bootstrap if you have a stale install. |
| XListenerSet `Accepted=False reason: NotAllowedByListeners`             | The base Gateway's `allowedListeners.namespaces.from` doesn't include this XListenerSet's namespace.            |
| XListenerSet `Accepted=False reason: Conflicted`                        | Listener name collides with another listener (base Gateway's or another XListenerSet's). Names must be globally unique. |
| HTTPRoute `Accepted=False reason: NotAllowedByListeners`                | The listener's `allowedRoutes.namespaces` doesn't include the HTTPRoute's namespace.                            |
| HTTPRoute `Accepted=False reason: NoMatchingParent`                     | Wrong group/kind in `parentRefs[]`. Double-check `group: gateway.networking.x-k8s.io kind: XListenerSet`.       |
| Data plane has too many listeners after teardown                        | An XListenerSet wasn't deleted before the Gateway. Delete XListenerSets first, then the Gateway.               |
| Port conflict between two XListenerSets                                 | Two contributors using the same `port:`. EG keeps the first and rejects the second with `Conflicted=True`.    |
| `kubectl get xlistenerset` returns "no resources"                       | The experimental Gateway API CRDs aren't installed (bootstrap should install them; check `kubectl get crd | grep xlistenersets`). |

## When XListenerSet ISN'T the right answer

- You need full isolation per team (separate Envoy processes,
  separate failure domains) — use multiple Gateways instead.
- All your listeners share identical config — just put them on the
  base Gateway directly.
- You're on Gateway API < 1.2 (no experimental channel installed
  yet) — XListenerSet doesn't exist yet.
- Your platform team is willing to own all listener changes
  centrally — the org overhead of XListenerSet isn't worth it.

The sweet spot: 3-20 tenant teams, each owning a small handful of
listener configs, on a cluster where running one Envoy per team
would be wasteful.

## Exercises

1. **Same port, different SNI.** Make both teams contribute an
   HTTPS listener on **:443** with their own hostnames
   (`blue.example.com`, `green.example.com`) and their own cert
   Secrets. EG should merge into ONE Envoy listener with two
   `filter_chains` distinguished by SNI. Confirm via
   `/config_dump`.

2. **Restrict by label.** Change the Gateway's
   `allowedListeners.namespaces.from: Selector` and add
   `selector.matchLabels: { tenant: blue }`. Label only
   team-blue's namespace with `tenant: blue`. Confirm
   team-green's XListenerSet is now rejected with
   `Accepted=False reason: NotAllowedByListeners`.

3. **Attach via the Gateway, not the XListenerSet.** Change
   `httproute-blue.yaml` to use `parentRefs[].kind: Gateway` with
   `sectionName: blue-http`. Same behavior; which feels cleaner
   in your org?

4. **What happens at name collision?** Add a second XListenerSet
   in team-blue that also uses listener name `blue-http`. Watch
   one go `Conflicted=True`. Rename to fix.

5. **Tear-down ordering.** Delete the Gateway FIRST (before the
   XListenerSets). What happens to the XListenerSet status? Does
   the data plane Service vanish? Restore by re-applying.

## Cleanup

```bash
make down       # tears down in reverse order (routes -> XLS -> Gateway -> backends -> ns)
```

## That's all of Phase 2

22 examples. From `01-helloworld-gateway` (a single HTTPRoute) to
this multi-tenant Gateway with three owners. PROGRESS.md has the
status summary for the whole set.

Suggested next steps:

- Pick an example that matches what you're building in production,
  fork it, evolve it.
- Combine examples: 05 (TLS) + 13 (JWT) + 16 (extAuth) + 19 (rate
  limit) is a realistic "authenticated API edge" stack.
- Submit issues / fixes back to this repo if you hit something the
  tutorial got wrong.
