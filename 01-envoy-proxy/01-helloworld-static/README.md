# 01 — Hello World, static config

The smallest useful Envoy config: one listener, one route, one cluster, one
backend. By the end of this example you should be able to answer:

- What does an Envoy config actually look like?
- What is a *listener*, a *filter chain*, an *HTTP filter*, a *route*, a
  *cluster*, an *endpoint* — and how do they fit together?
- How does a request flow from the wire to the backend and back?

## Prerequisites

- Docker and `docker compose`
- `curl` and `jq`

Versions pinned in this example:

- Envoy: `envoyproxy/envoy:v1.34.1`
- Python: `python:3.12-slim` (for the helloworld app)

## What we're building

```
              ┌────────────────────────────────┐
              │              Envoy             │
  curl ──▶  10000 ──▶ listener_http             │
              │        └─ http_connection_mgr   │
              │            └─ router            │
              │                └─ route "/" ▶ helloworld_cluster
              │                                 │
              │   admin ──▶ 9901                │
              └────────────────────────────────┘
                                │
                                ▼
                  ┌──────────────────────────┐
                  │  helloworld:8080  (Flask)│
                  └──────────────────────────┘
```

`docker compose` brings up two containers on a shared network:

- `helloworld` — the Flask app from [`apps/helloworld/`](../../apps/helloworld/),
  not exposed to the host. Envoy reaches it via the service name `helloworld`.
- `envoy` — the proxy. Exposes port `10000` (data plane) and `9901` (admin)
  to the host.

## Run it

```bash
make up        # docker compose up -d --build
make verify    # curl through Envoy + a peek at the admin endpoints
```

You should see something like:

```json
== GET http://localhost:10000/ ==
{
  "from_": "helloworld",
  "msg": "hello, world"
}
```

When you're done:

```bash
make down
```

## Walkthrough

Open [`envoy.yaml`](./envoy.yaml). It has three top-level sections.

### 1. `admin` — the introspection endpoint

```yaml
admin:
  address:
    socket_address:
      address: 0.0.0.0
      port_value: 9901
```

This binds an HTTP admin server on port `9901`. It's not on the request
path — it's just for you to inspect Envoy at runtime. We forward it to the
host so you can hit it directly:

```bash
curl -s localhost:9901/ready              # 200 LIVE
curl -s localhost:9901/listeners          # what's bound
curl -s localhost:9901/clusters           # upstream view
curl -s localhost:9901/stats | head       # counters/gauges/histograms
curl -s localhost:9901/config_dump | jq . # the entire live config
```

The next example (`02-config-anatomy`) gives this a proper tour. For now,
remember: **anything you ever want to know about a running Envoy is reachable
through `/config_dump`, `/clusters`, `/stats`, and `/listeners`**.

### 2. `static_resources.listeners` — what Envoy accepts

```yaml
listeners:
  - name: listener_http
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 10000
    filter_chains:
      - filters:
          - name: envoy.filters.network.http_connection_manager
            ...
```

A **listener** owns an `address:port`. Each listener has one or more
**filter chains**. A filter chain is a stack of **network filters** that
operate on raw TCP bytes. The most important network filter for our purposes
is the **HTTP Connection Manager** (HCM): it parses HTTP/1.1 or HTTP/2 off
the wire and exposes an HTTP-aware routing layer.

Inside the HCM we configure two things:

#### HTTP filters

```yaml
http_filters:
  - name: envoy.filters.http.router
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
```

HTTP filters are different from network filters — they run *inside* the HCM,
on parsed HTTP requests. They run in declared order. The **router** is the
terminal one: it actually dispatches the request to the upstream cluster.
Later examples insert more HTTP filters above the router (rate limit, JWT
auth, CORS, ext_authz, lua…). For now, only the router.

#### Route table

```yaml
route_config:
  virtual_hosts:
    - name: local_service
      domains: ["*"]
      routes:
        - match: { prefix: "/" }
          route: { cluster: helloworld_cluster }
```

A **virtual host** is selected by the `:authority` header (the Host header
in HTTP/1.1). With `domains: ["*"]` we match every request. Then we route by
**match** rules — here, any path with prefix `/`. The match's `route` block
tells Envoy what to do (forward to a cluster, redirect, return a fixed
response, …). We forward to `helloworld_cluster`.

### 3. `static_resources.clusters` — where Envoy forwards to

```yaml
clusters:
  - name: helloworld_cluster
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: helloworld_cluster
      endpoints:
        - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: helloworld
                    port_value: 8080
```

A **cluster** is "a logical group of upstream hosts that accept traffic from
Envoy". Three things matter here:

- **`type: STRICT_DNS`** — Envoy resolves `helloworld` via DNS, uses every
  returned A/AAAA record as an endpoint, and re-resolves periodically. With
  `docker compose` the service name `helloworld` resolves inside the Docker
  network. Other cluster types you'll meet later: `STATIC`, `LOGICAL_DNS`,
  `EDS` (xDS-driven, what Envoy Gateway uses), `ORIGINAL_DST`.
- **`lb_policy: ROUND_ROBIN`** — irrelevant with a single endpoint; example
  04 exercises this.
- **`load_assignment.endpoints[].lb_endpoints[]`** — the actual endpoint
  list. Static here; dynamic in xDS-driven setups.

### Putting it together: request flow

When you `curl http://localhost:10000/`:

1. **Listener** `listener_http` accepts the TCP connection on `:10000`.
2. The **HCM** parses the HTTP/1.1 request.
3. The HCM picks the virtual host `local_service` (matches `*`).
4. The route table picks the prefix `/` route → cluster `helloworld_cluster`.
5. HTTP filters run in order; only the **router** is configured.
6. The router selects an endpoint from the cluster (just one) and forwards.
7. Response comes back, filters run in reverse, HCM serialises it, listener
   writes it to the wire.

## Verify

`make verify` runs `verify.sh`. Read it — every command in it is something
you should know how to type by hand.

A few things to notice in the output:

- **`x-envoy-*` headers** on `/headers`. Envoy adds these as it forwards.
  `x-request-id` is the most common one to know — it's the request's
  identity across hops.
- **Access log on stdout**. Each request prints a single line in Envoy's
  default access log format. Watch with `make logs`. You'll see fields
  like `RESPONSE_FLAGS` (empty for a clean 200) — those become important
  when debugging (example `03-debugging` has the table).
- **`/clusters?cluster=helloworld_cluster`** shows the live endpoint state
  including health, last-resolution time, and per-endpoint counters.

## Exercises

Small modifications to build intuition. Edit `envoy.yaml`, then
`make down && make up`.

1. **Add a second route.** Make `/hi` route to the same cluster but rewrite
   the path to `/`. Hint: a `route` can have `prefix_rewrite: "/"`.
2. **Return a fixed response without going upstream.** Replace one route's
   `route:` block with a `direct_response:` returning `{ status: 200,
   body: { inline_string: "pong" } }`. Hit it with `curl`.
3. **Break the cluster on purpose.** Change `address: helloworld` to
   `address: doesnotexist`, restart, and `curl` again. Note the response
   status, the response body, and the `RESPONSE_FLAGS` in the access log.
   Then check `/clusters?cluster=helloworld_cluster` — what does the
   endpoint state look like?

## Cleanup

```bash
make down
```

## What's next

- **`02-config-anatomy`** — same setup, deep tour of the admin endpoints.
- **`03-routing-basics`** — multiple routes, header/query matching, rewrites.
