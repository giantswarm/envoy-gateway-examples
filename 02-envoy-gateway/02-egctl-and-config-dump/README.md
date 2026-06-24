# 02 — Reading the generated Envoy config (`/config_dump` + `egctl`)

Example 01 ended with a side-by-side mapping table. This example is
the deep dive: a tour of the **xDS resource types** as they appear in
`/config_dump`, a demonstration of **xDS convergence** (apply a new
HTTPRoute, watch the route config version bump), and a **single-request
trace** through the live config.

We also point out [`egctl`](https://github.com/envoyproxy/gateway/tree/main/cmd/egctl),
Envoy Gateway's CLI, which is a friendlier front-end over the same
endpoint.

By the end of this example you should be able to:

- Name the seven `/config_dump` section types and what xDS service
  each corresponds to.
- Pull listener / route / cluster / endpoint detail in one or two
  `jq` queries.
- Spot when a config update has *actually* converged on a data-plane
  pod (`version_info`).
- Trace a request `x-request-id` through admin endpoints + access logs.

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- `kubectl`, `curl`, `jq` on PATH.
- Optional: [`egctl`](https://gateway.envoyproxy.io/docs/install/install-egctl/).

This example creates its **own** Gateway (`inspect`) so it coexists
with example 01 without colliding.

## Run it

```bash
make up           # apply Gateway + HTTPRoute, wait until Programmed/Accepted
make verify       # 7-section walkthrough of /config_dump
make admin        # port-forward :19000 in another terminal for ad-hoc curls
make down         # delete only this example's resources
```

## The seven `/config_dump` sections

Envoy's admin endpoint exposes the live config split by **xDS resource
type**. Each entry in `configs[]` has a `@type` field naming the dump
struct. With Envoy Gateway running, the dump always contains:

| Section                          | xDS service | What's inside                                             |
|----------------------------------|-------------|------------------------------------------------------------|
| `BootstrapConfigDump`            | none (static) | The bootstrap envoy received at start (xDS endpoint, node ID, base clusters). |
| `ListenersConfigDump`            | LDS         | Active + warming listeners. EG-managed listeners are under `dynamic_listeners[]`. |
| `RoutesConfigDump`               | RDS         | The route table for each listener. `dynamic_route_configs[]`. |
| `ClustersConfigDump`             | CDS         | Upstream clusters. `dynamic_active_clusters[]`. |
| `EndpointsConfigDump`            | EDS         | Endpoints inside each cluster. Only included with `?include_eds`. |
| `SecretsConfigDump`              | SDS         | TLS material (key references, not the keys themselves). Empty here; populated by example 05. |
| `EcdsConfigDump`                 | ECDS        | Extension configs delivered via xDS. Empty here. |

The four dynamic ones (LDS/RDS/CDS/EDS) are how Envoy Gateway *pushes*
config to the data plane. Each carries a `version_info` string that
EG bumps on every change.

## Useful one-liners

Once you `make admin` (or set up your own port-forward), every section
is just a `curl + jq` away.

```bash
# Top-level — which sections are present
curl -s localhost:19000/config_dump | jq '[.configs[]."@type"]'

# Listener names + addresses
curl -s localhost:19000/config_dump | jq '
  .configs[] | select(."@type"|endswith("ListenersConfigDump"))
             | .dynamic_listeners[]
             | {name, address: .active_state.listener.address.socket_address}'

# Routes — virtual_hosts and their domains
curl -s localhost:19000/config_dump | jq '
  .configs[] | select(."@type"|endswith("RoutesConfigDump"))
             | .dynamic_route_configs[].route_config.virtual_hosts
             | map({name, domains, n_routes: (.routes|length)})'

# Cluster names + EDS endpoints actually serving
curl -s 'localhost:19000/config_dump?include_eds' | jq '
  .configs[] | select(."@type"|endswith("EndpointsConfigDump"))
             | .dynamic_endpoint_configs[].endpoint_config
             | {cluster: .cluster_name,
                endpoints: [.endpoints[].lb_endpoints[].endpoint.address.socket_address]}'

# Per-cluster stats (the real-time view of health + traffic)
curl -s "localhost:19000/clusters?format=json" | jq '
  .cluster_statuses[] | {name, host_statuses: [.host_statuses[]
    | {addr: .address.socket_address.address,
       health: .health_status,
       rq_total: (.stats[] | select(.name=="rq_total").value // "0")
      }]}'

# Live access log of a specific request id
kubectl -n envoy-gateway-system logs deploy/envoy-default-... | grep $XID
```

If you have `egctl`:

```bash
egctl config envoy-proxy all      -n envoy-gateway-system
egctl config envoy-proxy listener -n envoy-gateway-system
egctl config envoy-proxy route    -n envoy-gateway-system
egctl config envoy-proxy cluster  -n envoy-gateway-system
egctl config envoy-proxy endpoint -n envoy-gateway-system
egctl config envoy-proxy bootstrap -n envoy-gateway-system

# Without applying anything — show the Envoy config that this YAML
# WOULD produce. Great for code review.
egctl experimental translate --type gateway-api \
  -f manifests/gateway.yaml -f manifests/httproute.yaml
```

## Watching xDS converge

Each xDS resource type carries `version_info` — an opaque string EG
bumps on every change. When you apply a new HTTPRoute:

1. EG reconciles the change and computes new Envoy config.
2. EG pushes new resources to the data plane via gRPC streaming xDS.
3. The data plane swaps in the new resources; `version_info` rises.
4. Future requests use the new routing.

The verify script demonstrates the bump:

```
== 6. xDS convergence — apply a new HTTPRoute and watch RDS update ==

-- version_info BEFORE --
    7f3d2a8c

-- Applying manifests/httproute-extra.yaml... --
-- version_info AFTER --
    e9b1f404

-- New virtual_hosts (matched by domain) --
    [{"name":"hello-base/...", "domains":["*"]},
     {"name":"hello-extra/...","domains":["extra.local"]}]
```

A common debugging trick: if you change a resource and behavior
doesn't update, look at the version_info on the data-plane pod. If it
hasn't moved, EG hasn't pushed yet — check the controller logs.

## Tracing a single request

When you're debugging "request X went somewhere unexpected", the
walk-back is always: **listener → route → cluster → endpoint**, plus
the **access log line** identified by `x-request-id`. The verify
script's step 7 walks this for one live request.

```
1. curl localhost:8080/   →   captures x-request-id from response header
2. listener that bound :80     →   ListenersConfigDump
3. virtual_host + route that matched  →   RoutesConfigDump
4. cluster that the route picked      →   ClustersConfigDump
5. endpoints behind that cluster      →   EndpointsConfigDump (?include_eds)
6. access log line for that x-request-id   →   envoy pod logs
```

In a real production debug you'd start at step 6 (the access log line
showing what *actually* happened) and walk forward.

## How EG names the resources it generates

EG uses deterministic naming so you can grep:

| What                | Pattern                                                                |
|---------------------|------------------------------------------------------------------------|
| Listener            | `<gateway-namespace>/<gateway-name>/<listener-name>`                  |
| Route config        | `<gateway-namespace>/<gateway-name>/<listener-name>`                  |
| Virtual host        | `<httproute-namespace>/<httproute-name>/<rule-index>/match-N/<host>` |
| Cluster             | `httproute/<httproute-namespace>/<httproute-name>/rule/<rule-index>` |
| Cluster (Backend)   | `backend/<backend-namespace>/<backend-name>/rule/<rule-index>`       |

Names will look long in `/config_dump` — that's why. Memorize the
shape; once you do, every CR maps obviously to its slice of the live
config.

## Common follow-ups

- **`stats?filter=...`** — same patterns as Phase 1 example 02. Stats
  are scoped per HCM and per cluster; the `stat_prefix` for EG-managed
  HCMs follows the listener naming above (with `/` → `.`).
- **`clusters`** — real-time view, not the static config. Includes
  health flags, last DNS resolution time (for non-EDS clusters), and
  per-endpoint counters. Indispensable when a cluster looks fine in
  `ClustersConfigDump` but traffic to it 503s.
- **`/ready` / `/healthcheck/fail`** — same readiness probe + drain
  controls as Phase 1; EG-managed pods expose them on `:19000`.

## Common failure modes

| Symptom                                                | Likely cause                                                        |
|--------------------------------------------------------|----------------------------------------------------------------------|
| `dynamic_listeners` is empty                            | Gateway exists but no listener / Programmed=False. `make status`. |
| `dynamic_route_configs` empty                          | No HTTPRoute attached / `Accepted=False`. Check parentRefs.         |
| Cluster present but `EndpointsConfigDump` empty for it  | Service has no endpoints. `kubectl get endpoints -n <ns>`.          |
| `version_info` never changes after apply                | EG controller down or backed up. `kubectl -n envoy-gateway-system logs deploy/envoy-gateway`. |
| `egctl` errors with "no such file" on socket           | Older egctl / new EG version mismatch. Bump egctl or use curl.       |

## Exercises

1. **Watch a single resource by name.** Use `?resource=dynamic_listeners`
   on `/config_dump` to fetch *just* the listeners (smaller, faster).
   Combine with `--mask=configs.X` to slice further.

2. **Diff two snapshots.** `make verify` (which writes the snapshot to
   stdout). Apply an HTTPRoute change. Take a second snapshot. Diff
   them with `diff <(jq -S . a) <(jq -S . b)`. Why is this nicer than
   reading two full dumps?

3. **Trace by `x-envoy-original-path`.** The default access log shows
   the *original* path even after rewrite. Repeat step 7 of verify
   with a route that rewrites the path (see Phase 2 example 03) —
   confirm the access log retains the original.

4. **`egctl experimental translate`.** Take `manifests/httproute.yaml`,
   change something, and run `egctl experimental translate ...` to see
   the Envoy config the new YAML would produce — without applying it.
   What changes about the rendered cluster name when you change the
   HTTPRoute name?

5. **Capture cluster stats with `/stats?format=json`.** Hit the data
   plane 50 times via `make pf`, then dump
   `cluster.<cluster-name>.upstream_rq_total`. Verify the number lines
   up with the requests sent.

## Cleanup

```bash
make down
```

## What's next

- `03-httproute-matching-and-filters` — what example 03 of Phase 1
  taught (path / header / query matching, rewrites, redirects) but
  expressed as `HTTPRoute` rules + filters.
