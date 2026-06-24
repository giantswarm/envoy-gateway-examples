# 05 — Health checks and outlier detection

Four backends in one cluster. Three are normal (`hello-a`, `hello-b`,
`hello-c`); a fourth (`hello-bad`) has the new `BREAK=true` env that
makes every request return HTTP 500. We turn on **active health checks**
and **outlier detection** and watch Envoy keep the cluster honest.

By the end of this example you should be able to answer:

- What's the difference between an *active* health check and *outlier*
  (passive) detection? When do you need each?
- Which `health_checks` fields actually matter day-to-day?
- What ejection lifecycle does outlier detection follow?
- Where do I see *which* endpoint is unhealthy and *why*?
- What is "panic mode" and how do I avoid getting into it accidentally?

## Prerequisites

- Done [`01`](../01-helloworld-static/) through [`04`](../04-load-balancing/).
- Docker, `docker compose`, `curl`, `jq`.
- Familiar with the helloworld `/`, `/fail`, and the new `BREAK` env from
  [`apps/helloworld/`](../../apps/helloworld/).

## Run it

```bash
make up
make verify   # ~30 seconds end-to-end; it stops + restarts hello-c
make down
```

`verify.sh` walks through six checkpoints: initial cluster state, normal
distribution, kill `hello-c`, distribution while down, restart, and
distribution after recovery. It also prints the relevant `/stats`
counters at the end.

## Active health checks

```yaml
health_checks:
  - timeout: 1s
    interval: 2s
    unhealthy_threshold: 2
    healthy_threshold: 2
    interval_jitter: 500ms
    http_health_check:
      path: "/"
      expected_statuses:
        - { start: 200, end: 300 }
```

- **`interval`** — how often Envoy probes each endpoint.
- **`timeout`** — per-probe deadline. Past this, the probe counts as a
  failure.
- **`unhealthy_threshold`** — consecutive failures before an endpoint is
  marked `FAILED_ACTIVE_HC`. With `interval: 2s` and `threshold: 2` it
  takes about 4 seconds to detect a dead backend.
- **`healthy_threshold`** — consecutive successes before recovery. Stops
  flapping on a backend that's intermittently up.
- **`interval_jitter`** — random delay added per probe so all probes
  don't hit upstream at the exact same moment.
- **`http_health_check.path`** — the URL probed. We use `/`; in
  production you usually want a cheap, side-effect-free endpoint like
  `/healthz` or `/livez`.
- **`expected_statuses`** — half-open ranges `[start, end)`. Default is
  `200` only. The example accepts any 2xx for illustration.

Other check types you'll meet:

- **`tcp_health_check`** — connect + optional payload exchange. Use for
  non-HTTP backends.
- **`grpc_health_check`** — proper gRPC health checking protocol
  (`grpc.health.v1.Health/Check`). Use whenever the backend speaks gRPC.
- **`custom_health_check`** — Wasm/Lua, escape hatch.

### How active HC interacts with load balancing

A failed endpoint is removed from the load-balancing pool. Round robin
walks the remaining N-1. Ring hash recomputes around them (so 1/N of the
keys remap). Outlier ejection has the same effect.

## Outlier detection (passive)

```yaml
outlier_detection:
  consecutive_5xx: 5
  interval: 5s
  base_ejection_time: 10s
  max_ejection_percent: 50
  enforcing_consecutive_5xx: 100
  enforcing_consecutive_gateway_failure: 100
```

- **`consecutive_5xx`** — after N consecutive 5xx (including locally
  generated ones if `enforcing_consecutive_gateway_failure: 100`), eject
  the endpoint.
- **`interval`** — how often the detector evaluates counters.
- **`base_ejection_time`** — initial ejection duration. Each subsequent
  ejection of the same endpoint multiplies it (`base * ejection_count`),
  with a cap.
- **`max_ejection_percent`** — hard cap on the fraction of the cluster
  that can be ejected. With 4 endpoints and `50`, at most 2 can be out at
  once. Prevents *panic mode* (see below).
- **`enforcing_*`** — these are 0–100 probabilities; `100` means
  "always enforce". Use lower values to A/B test new outlier rules in
  production.

The other knobs (`success_rate_*`, `failure_percentage_*`,
`split_external_local_origin_errors`) refine the criteria. Start with
`consecutive_5xx` — it's noisy enough to catch real problems without
false ejections under spiky load.

### Active HC vs. outlier detection

| Concern                  | Active HC                | Outlier Detection      |
|--------------------------|--------------------------|------------------------|
| Generates extra traffic? | Yes (one probe per `interval` per endpoint) | No (uses real traffic) |
| Catches process death?   | Yes, quickly             | No                     |
| Catches slow/error tail? | Only if probe hits the bug | Yes                  |
| Needs a probe endpoint?  | Yes                      | No                     |
| Recovery time            | `healthy_threshold * interval` | `base_ejection_time` (grows with repeats) |

Use **both** when you can. We do here.

## Panic mode — the failure-mode you must know

When the percentage of healthy endpoints in a cluster drops below
`healthy_panic_threshold` (default **50%**), Envoy enters **panic mode**:
it ignores health status and load-balances across **all** endpoints,
including the unhealthy ones. The reasoning: "if half the cluster looks
sick, maybe the health-check signal itself is wrong; better to serve
some traffic than zero."

Counter-intuitive but real. Two things follow:

1. **Don't set `max_ejection_percent` too high.** If outlier ejects 75%
   of a 4-endpoint cluster, you're below panic threshold and Envoy
   starts sending traffic to the ejected endpoints anyway. Cap
   ejection at 50% (the default we use here).
2. **Watch `cluster.<name>.lb_healthy_panic`.** Non-zero means you've
   spent time in panic mode. If you don't want that behaviour, set
   `common_lb_config.healthy_panic_threshold.value: 0` to disable.

## What the verify script will show

When `make verify` runs you should see roughly this:

1. **Initial state.** `hello-bad` shows up as `FAILED_ACTIVE_HC` in
   `endpoint_status`. The other three are healthy.
2. **30 requests → distribution.** `hello-a/b/c` each get ~10; `hello-bad`
   gets 0.
3. **Stop `hello-c`.** After ~4 seconds (`unhealthy_threshold * interval`)
   it's `FAILED_ACTIVE_HC`.
4. **30 requests.** Roughly 15 each on `hello-a` and `hello-b`. None on
   `hello-c` or `hello-bad`.
5. **Restart `hello-c`.** After ~4 seconds it's healthy again.
6. **30 requests.** Back to ~10/10/10 across `a/b/c`.

If the distribution in step 4 includes responses from `hello-c` or
`hello-bad`, you've slipped into panic mode — too few healthy endpoints.
Check `lb_healthy_panic` in the stats.

## Useful diagnostics

```bash
# Per-endpoint, including health flags.
curl -s 'localhost:9901/clusters?cluster=helloworld_cluster'

# Just the health-related counters.
curl -s 'localhost:9901/stats?filter=cluster.helloworld_cluster.(health_check|outlier|lb_healthy_panic)'

# JSON view, easier to script against.
curl -s 'localhost:9901/clusters?format=json' \
  | jq '.cluster_statuses[] | select(.name=="helloworld_cluster") | .host_statuses[] | {address: .address.socket_address.address, health: .health_status}'

# Watch live (refresh every 1s).
watch -n1 "curl -s 'localhost:9901/clusters?cluster=helloworld_cluster' | grep -E 'hostname|health_flags'"
```

## Exercises

1. **Tune for slower detection.** Bump `interval` to `10s` and
   `unhealthy_threshold` to `3`. `make reload`. How long does step 3
   now take? Why might you want this in production (hint: cost of probe
   traffic vs. detection latency)?

2. **gRPC backend.** Conceptual: replace `http_health_check` with
   `grpc_health_check { service_name: "my.Service" }`. Why is HTTP probing
   a poor choice for a gRPC backend? (Hint: gRPC uses HTTP/2 trailers
   for status; a 200 on the HTTP layer doesn't mean the gRPC service is
   actually healthy.)

3. **Trigger outlier detection in isolation.** Temporarily remove the
   `health_checks` block, `make reload`. Now active HC won't catch
   `hello-bad`, but outlier detection still should. Send 10 requests via
   `curl localhost:10000/` repeatedly until `hello-bad` accumulates 5
   consecutive 5xx and gets ejected. Verify with
   `curl -s 'localhost:9901/stats?filter=outlier.ejections_active'`.

4. **Panic mode.** Stop two backends so only `hello-a` is healthy
   (`docker compose stop hello-b hello-c`). Watch the
   `lb_healthy_panic` counter on `cluster.helloworld_cluster.*`. Then
   send 30 requests — do any unhealthy backends start receiving traffic
   again? Restore by `make up`.

5. **Custom probe path.** Add a `/healthz` route in `apps/helloworld/`
   that always returns `200 ok` regardless of `BREAK`, change
   `http_health_check.path` to `/healthz`, and observe that `hello-bad`
   now passes active HC even while serving 500s. This is the failure
   mode that outlier detection exists to catch.

## Cleanup

```bash
make down
```

## What's next

- **`06-timeouts-retries`** — per-route timeouts, idempotent retries,
  exponential backoff, host predicates. The other half of "make the
  cluster honest".
