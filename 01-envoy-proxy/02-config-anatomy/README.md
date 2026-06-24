# 02 — Config anatomy: touring the admin endpoints

Same data-plane setup as [`01-helloworld-static`](../01-helloworld-static/) —
one listener, one route, one cluster. We're not changing the request path.
What we *are* doing is learning to **introspect** a running Envoy through its
admin endpoint at `:9901`.

By the end of this example you should be able to:

- Tell, from a running Envoy you've never seen before, what it's bound to,
  where it's sending traffic, and how it's configured — without reading the
  source YAML.
- Read `/config_dump` and pick out bootstrap / listeners / clusters / routes.
- Read `/clusters` and understand endpoint health, last DNS resolution time,
  and per-endpoint counters.
- Read `/stats` in text, JSON, and Prometheus format, and filter to the
  counters you care about.
- Know which admin endpoints are read-only and which can change state.

If you find yourself debugging Envoy in production later, this is the kit
you'll reach for first.

## Prerequisites

- Done [`01-helloworld-static`](../01-helloworld-static/) — same shape, with
  the YAML walkthrough.
- Docker, `docker compose`, `curl`, `jq`.

## Run it

```bash
make up            # build + start (same as example 01)
make tour          # scripted walk through the admin endpoints
make traffic       # generate 50 requests so counters move
make tour          # re-run to see the deltas
make down
```

## The admin endpoint, end-to-end

The admin server lives on the port from the `admin:` block of the config —
`:9901` here. It's an ordinary HTTP server. `curl -s localhost:9901/help`
lists every route it exposes. We'll cover the ones that matter.

> **State-changing endpoints.** Most admin paths are GET and read-only. A
> handful accept POST and *will* change runtime behavior. The ones to know:
>
> - `POST /logging?LEVEL=debug` — change the log level for all components.
> - `POST /logging?<component>=debug` — per-component level.
> - `POST /runtime_modify?key=value` — set runtime values.
> - `POST /reset_counters` — zero all counters.
> - `POST /drain_listeners` — start the graceful-shutdown drain.
> - `POST /quitquitquit` — exit cleanly.
> - `POST /healthcheck/fail` and `/healthcheck/ok` — fail/restore the
>   admin's own health filter (if configured).
>
> In production you want to bind the admin server only to localhost or a
> dedicated interface and gate it with network policy / a sidecar. The
> example here exposes it to the host purely for tutorial use.

### 1. `/ready` — readiness probe

```bash
$ curl -s localhost:9901/ready
LIVE
```

Returns `200 LIVE` once Envoy has finished initialising listeners and is
serving. Anything else (e.g. `400 PRE_INITIALIZING`, `503 DRAINING`) means
it's not yet (or no longer) accepting traffic. **Use this as your
Kubernetes `readinessProbe`** in Phase 2 — and `/healthcheck/fail` to drain
for graceful shutdown.

### 2. `/server_info` — what's running

```bash
curl -s localhost:9901/server_info | jq .
```

Tells you the Envoy version, build, current state (`LIVE`, `DRAINING`,
`PRE_INITIALIZING`, etc.), hot-restart epoch, and the CLI flags it was
started with. First thing to check when "we're seeing weird behavior and
nobody knows what version is deployed".

### 3. `/listeners` — what's bound

```bash
$ curl -s localhost:9901/listeners
listener_http::0.0.0.0:10000

$ curl -s "localhost:9901/listeners?format=json" | jq .
```

The text form is `name::address`. The JSON form is what you want when you
have many listeners or need to script. In Phase 2 you'll see Envoy Gateway
generate listeners named like `default/eg/http` — same shape, just longer
names.

### 4. `/clusters` — upstream view

The single most useful admin endpoint when something is broken. Per cluster,
per endpoint, you get:

- Discovery state (`STRICT_DNS`, `EDS`, `STATIC`…)
- Live address and last resolution timestamp
- Health: `health_flags::healthy` / `FAILED_ACTIVE_HC` / `FAILED_OUTLIER_CHECK`
- Counters: `cx_active`, `cx_total`, `rq_active`, `rq_total`, `rq_error`,
  `cx_connect_fail`, `cx_destroy_*`
- Per-endpoint local priority, weight, region

```bash
# Plain text, filtered to one cluster
curl -s "localhost:9901/clusters?cluster=helloworld_cluster"

# JSON, scoped with jq
curl -s "localhost:9901/clusters?format=json" \
  | jq '.cluster_statuses[] | select(.name=="helloworld_cluster")'
```

If you're debugging "Envoy returns 503 / UH" — the answer is in here. An
unhealthy or empty endpoint list is *the* most common cause.

### 5. `/stats` — counters, gauges, histograms

Envoy emits a *lot* of stats. The naming convention is dot-separated:

```
cluster.<cluster_name>.<counter>
listener.<address>.<counter>
http.<stat_prefix>.<counter>
server.<counter>
```

`<stat_prefix>` is the HCM's `stat_prefix` field — `ingress_http` in our
YAML. That's how you'd correlate one listener's HTTP counters to its config.

Common metrics worth knowing:

| Stat                                                | Meaning |
|------------------------------------------------------|---------|
| `cluster.X.upstream_rq_total`                        | Requests sent to upstream cluster X |
| `cluster.X.upstream_rq_2xx` (and `4xx`, `5xx`)       | Responses bucketed by status class |
| `cluster.X.upstream_rq_time`                         | Histogram of upstream response time |
| `cluster.X.upstream_cx_active` / `_total`            | Active / total upstream connections |
| `cluster.X.upstream_cx_connect_fail`                 | Could-not-connect count |
| `cluster.X.upstream_cx_destroy_remote_with_active_rq`| Upstream closed mid-request — flaky backend smell |
| `listener.0.0.0.0_10000.downstream_cx_total`         | TCP accepts on the listener |
| `http.ingress_http.downstream_rq_total`              | Requests parsed by this HCM |
| `http.ingress_http.no_route`                         | Requests that didn't match any route — routing bug |
| `server.live`                                        | 1 while serving |

```bash
# Text, filtered
curl -s "localhost:9901/stats?filter=cluster.helloworld_cluster"

# Only stats with non-zero values
curl -s "localhost:9901/stats?usedonly"

# JSON (for scripting)
curl -s "localhost:9901/stats?format=json" | jq '.stats[0:5]'

# Prometheus exposition (scrape this from Prometheus)
curl -s localhost:9901/stats/prometheus | head
```

Run `make traffic` (50 requests through `/`), then re-check
`cluster.helloworld_cluster.upstream_rq_2xx` — it should be 50 higher.

### 6. `/config_dump` — the live config tree

`/config_dump` returns the *effective* configuration as Envoy currently
sees it, organised by xDS resource type. For our static setup the
sections are:

- `BootstrapConfigDump` — what was in `envoy.yaml`.
- `ListenersConfigDump` — both static (`static_listeners`) and dynamic
  (`dynamic_listeners`) listeners. In Phase 2 with Envoy Gateway, the
  dynamic side is where the action is.
- `ClustersConfigDump` — same split: `static_clusters` and `dynamic_*`.
- `RoutesConfigDump` — same.
- `SecretsConfigDump` — TLS material (key references, not the keys
  themselves).
- `EcdsConfigDump` — Envoy Config-Driven extension configs (filters
  delivered via xDS).

```bash
# Which sections are present?
curl -s localhost:9901/config_dump | jq '[.configs[]."@type"]'

# Pull out the bootstrap node ID
curl -s localhost:9901/config_dump \
  | jq '.configs[] | select(."@type" | endswith("BootstrapConfigDump")) | .bootstrap.node'

# All listeners we know about, by name + address
curl -s localhost:9901/config_dump \
  | jq '.configs[] | select(."@type" | endswith("ListenersConfigDump")) | .static_listeners[].listener | {name, address}'

# Cluster summary
curl -s localhost:9901/config_dump \
  | jq '.configs[] | select(."@type" | endswith("ClustersConfigDump")) | .static_clusters[].cluster | {name, type, lb_policy}'
```

Useful query params:

- `?include_eds` — also return endpoint discovery state.
- `?mask=configs.0.bootstrap` — narrow the response (faster for big dumps).
- `?resource=dynamic_listeners` — return only a named resource set.

In Phase 2 you'll routinely diff `/config_dump` from two Envoy pods to
understand a discrepancy.

### 7. `/runtime` and `/runtime_modify`

Runtime is Envoy's feature-flag layer — values that can change without a
restart. Most of what's exposed is internal tuning (timeouts, defaults,
experiment toggles). Useful in this example only as awareness:

```bash
curl -s localhost:9901/runtime | jq '.entries | keys[:5]'
# POST to change one (not used in this example):
# curl -X POST "localhost:9901/runtime_modify?envoy.reloadable_features.X=false"
```

### 8. `/logging` — live log level control

```bash
# Read current levels
curl -s localhost:9901/logging

# Bump everything to debug
curl -X POST 'localhost:9901/logging?level=debug'

# Or per-component (the names are the same as in the GET output)
curl -X POST 'localhost:9901/logging?http=debug&router=debug'
```

Useful flip when you can't reproduce locally but you can capture a brief
trace from production. Don't leave it on `trace` in production — it's
expensive.

### 9. `/certs` — TLS material in use

Empty in this example because we haven't configured any TLS. We'll come back
to it in [`09-tls-termination`](../09-tls-termination/). When populated, it
lists each loaded cert's CN, SANs, validity window, and the secret name —
indispensable when "cert-manager renewed but Envoy is still serving the
old cert".

## The access log, briefly

You've been seeing one log line per request in `docker compose logs envoy`.
That's Envoy's default access log format:

```
[%START_TIME%] "%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%"
%RESPONSE_CODE% %RESPONSE_FLAGS% %BYTES_RECEIVED% %BYTES_SENT% %DURATION%
%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)% "%REQ(X-FORWARDED-FOR)%"
"%REQ(USER-AGENT)%" "%REQ(X-REQUEST-ID)%" "%REQ(:AUTHORITY)%" "%UPSTREAM_HOST%"
```

The field to know is `%RESPONSE_FLAGS%`. It's two letters describing how
the request ended. Empty means "clean response from upstream". The common
ones (mini reference — we cover this in depth in `03-debugging`):

| Flag | Meaning |
|------|---------|
| `NR`  | No route configured for request |
| `UH`  | No healthy upstream |
| `UF`  | Upstream connection failure |
| `UC`  | Upstream connection termination |
| `URX` | Upstream retry limit exceeded |
| `UT`  | Upstream request timeout |
| `DC`  | Downstream connection termination |
| `LH`  | Local service failed health check |
| `RL`  | Rate-limited (local rate limit) |

We'll customise the log format in [`17-access-logging`](../17-access-logging/).

## Exercises

1. **Make a counter move.** Run `make traffic`, then watch
   `cluster.helloworld_cluster.upstream_rq_total` change with:

   ```bash
   watch -n1 "curl -s 'localhost:9901/stats?filter=cluster.helloworld_cluster.upstream_rq_total'"
   ```

2. **Break the cluster and read the diagnosis.** Edit `envoy.yaml`, point
   the cluster address at `doesnotexist`, `make down && make up`. Then:

   - What does `/ready` say?
   - What does `/clusters?cluster=helloworld_cluster` show for endpoint health?
   - What `%RESPONSE_FLAGS%` does a `curl localhost:10000/` produce in the
     access log?

3. **Crank the log level.** With Envoy running, send one request, then:

   ```bash
   curl -X POST 'localhost:9901/logging?level=debug'
   curl -s localhost:10000/
   docker compose logs --tail=80 envoy
   curl -X POST 'localhost:9901/logging?level=info'   # turn it back
   ```

   What new log lines do you see for that single request?

## Cleanup

```bash
make down
```

## What's next

- **`03-routing-basics`** — multiple routes, header/query matching, prefix
  rewrites, redirects. The route table starts doing real work.
