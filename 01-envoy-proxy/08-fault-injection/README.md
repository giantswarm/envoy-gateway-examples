# 08 — Fault injection

We've been **making the cluster honest** for the last four examples
(health checks, retries, timeouts, circuit breakers). This one makes
the cluster **dishonest on demand**, so we can verify that those
mechanisms actually behave the way we think they do under failure.

The HTTP fault filter
(`envoy.filters.http.fault`) sits in the HCM chain and can inject:

- **Delays** — sleep for N before forwarding (test client timeouts,
  retry-with-backoff).
- **Aborts** — return a fixed status without forwarding (test retry
  policies, circuit breakers, error pages).
- **Per-request decisions** controlled by client-supplied headers
  (controlled chaos for one user / one test run).

By the end of this example you should be able to answer:

- Where does the fault filter live in the HCM chain?
- How do I scope a fault to one route without touching the others?
- How do `percentage` and `header_*` interact?
- What does the access log look like when Envoy aborts a request?
- How would I use this to verify the work from examples 05–07?

## Prerequisites

- Done [`01`](../01-helloworld-static/) through
  [`07`](../07-circuit-breakers/).
- Docker, `docker compose`, `curl`, `jq`.

## Run it

```bash
make up
make verify       # ~10s; runs all 8 fault scenarios
make down
```

## Where the filter lives

```yaml
http_filters:
  - name: envoy.filters.http.fault
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.fault.v3.HTTPFault
      # Empty -> passthrough. Per-route opt-in below.
  - name: envoy.filters.http.router
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
```

Two things to notice:

1. **Order matters.** Filters run top-down on the request. `fault`
   *must* be above `router` — once `router` dispatches upstream, the
   chain is committed.
2. **Globally a no-op.** With an empty `HTTPFault` typed_config, the
   filter is installed but does nothing. Specific routes opt in via
   `typed_per_filter_config` (next section).

## Per-route opt-in via `typed_per_filter_config`

```yaml
- match: { prefix: "/delay" }
  route: { cluster: hello_cluster, regex_rewrite: { ... } }
  typed_per_filter_config:
    envoy.filters.http.fault:                                         # filter name
      "@type": type.googleapis.com/envoy.extensions.filters.http.fault.v3.HTTPFault
      delay:
        fixed_delay: 2s
        percentage: { numerator: 100, denominator: HUNDRED }
```

Notes on the shape:

- The **key** (`envoy.filters.http.fault`) is the filter's `name` from
  the HCM chain. Wrong key here → the override is silently ignored.
- The **type** (`@type`) is the same proto type as the global filter
  config.
- The per-route config **replaces** the global config for that route.
  (For other filters it can be `merge`, but the fault filter is
  replace-only.)

You can also attach the same config at the virtual host level
(`virtual_hosts[].typed_per_filter_config`) or to a weighted-cluster
sub-route.

## Delays

```yaml
delay:
  fixed_delay: 2s
  percentage: { numerator: 100, denominator: HUNDRED }
```

Variants:

- **`fixed_delay`** — fixed duration, applied to `percentage` of requests.
- **`header_delay: {}`** — duration comes from the request header
  `x-envoy-fault-delay-request` in milliseconds. `percentage` gates how
  often the header is honored.

When a delay fires, Envoy pauses the request between the fault filter
and the router. The upstream connection is opened only *after* the
delay; nothing on the backend sees the delay at all. Useful for asking
"what happens to my client if upstream is slow?" without actually
asking upstream to be slow.

## Aborts

```yaml
abort:
  http_status: 503
  percentage: { numerator: 100, denominator: HUNDRED }
```

Variants:

- **`http_status`** — fixed HTTP status returned to the client.
- **`grpc_status`** — gRPC status code; use this for gRPC routes (the
  filter returns the correct trailer-based response).
- **`header_abort: {}`** — status comes from `x-envoy-fault-abort-request`
  (HTTP) or `x-envoy-fault-abort-grpc-request` (gRPC).

When an abort fires, no upstream hop happens. Access log shows the
status (here 503) and `%RESPONSE_FLAGS%` includes **`FI`** (Fault
Injection).

## `percentage` — the probability proto

```yaml
percentage:
  numerator: 25       # any uint32
  denominator: HUNDRED  # one of HUNDRED, TEN_THOUSAND, MILLION
```

`numerator / denominator` is the probability. For small percentages
(e.g. canary-style 0.01%), bump the denominator instead of running into
integer rounding:

```yaml
percentage: { numerator: 1, denominator: TEN_THOUSAND }   # 0.01%
percentage: { numerator: 1, denominator: MILLION }        # 0.0001%
```

## Header-driven faults

```yaml
delay:
  header_delay: {}
  percentage: { numerator: 100, denominator: HUNDRED }
abort:
  header_abort: {}
  percentage: { numerator: 100, denominator: HUNDRED }
```

Now the *client* asks for the fault:

| Header                                     | Effect                                              |
|--------------------------------------------|-----------------------------------------------------|
| `x-envoy-fault-delay-request: <ms>`        | Delay this request by N milliseconds                |
| `x-envoy-fault-delay-request-percentage: <0-100>` | Gate the delay header to a sub-percentage     |
| `x-envoy-fault-abort-request: <status>`    | Abort this request with the given HTTP status        |
| `x-envoy-fault-abort-request-percentage: <0-100>` | Gate the abort header to a sub-percentage     |
| `x-envoy-fault-abort-grpc-request: <code>` | Abort with gRPC status                              |

Both can be set on the same request. Order: delay fires first
(sleeps), then abort (returns). The verify script's step 8 hits both at
once.

> **Production hygiene.** Header-driven faults are dangerous to expose
> to untrusted clients — anyone who can set `x-envoy-fault-abort-request`
> can DoS the route. In production you put the fault filter only on
> internal listeners, or strip the `x-envoy-fault-*` headers from
> external traffic with `request_headers_to_remove` on the edge route.

## Runtime-controlled percentages

Either `delay` or `abort` can also carry `runtime_key` (older field
name) / `percentage` from runtime:

```yaml
abort:
  http_status: 503
  percentage: { numerator: 0, denominator: HUNDRED }   # off by default
  runtime_key: fault.abort.percentage_for_route_x
```

Then at runtime you flip it on via the admin endpoint:

```bash
curl -X POST "localhost:9901/runtime_modify?fault.abort.percentage_for_route_x=10"
```

Useful for kill-switch style chaos: turn it on for an hour, observe how
the system reacts, turn it off — no `reload` needed.

## What the verify script tests

| Step | URL / header                                    | Expectation                          |
|------|-------------------------------------------------|--------------------------------------|
| 1    | `GET /normal`                                   | Fast 200                             |
| 2    | `GET /delay`                                    | 200 after exactly 2s                 |
| 3    | `GET /abort-100`                                | 503 in milliseconds; `FI` flag       |
| 4    | `GET /abort-25` × 100                           | ~25 × 503, ~75 × 200                 |
| 5    | `GET /header` (no fault headers)                | Fast 200                             |
| 6    | `GET /header` with `delay-request: 1500`        | 200 after 1.5s                       |
| 7    | `GET /header` with `abort-request: 418`         | 418 in milliseconds                  |
| 8    | `GET /header` with both                         | Total ~delay; status from abort      |

The fault filter emits its own counters. Useful ones:

```
http.<stat_prefix>.fault.aborts_injected
http.<stat_prefix>.fault.delays_injected
http.<stat_prefix>.fault.faults_overflow
http.<stat_prefix>.fault.active_faults
```

With `stat_prefix: ingress_http` (our HCM), the keys are
`http.ingress_http.fault.*`.

## Connecting to earlier examples

This is where chaos testing gets practical. With this filter installed
on a Envoy in front of any service, you can answer:

- "Does my client time out cleanly at the SLO when the server is slow?"
  → use `/delay` with `fixed_delay: <SLO + 50ms>`.
- "Does my retry policy actually retry on 503?" (example 06) →
  point `retry_on: 5xx` at `/abort-100` and watch
  `upstream_rq_retry_success` climb.
- "Does my client back off when the circuit breaker (example 07) says
  503 + `x-envoy-overloaded`?" → use `/abort-100` (returns 503 but
  *no* overloaded header) and compare.
- "Do my downstream timeouts compose correctly across services?" →
  pin the `x-envoy-fault-delay-request` header through a tracing
  context.

## Exercises

1. **Inject a slow path that retries fix.** Add a route `/flaky-abort`
   with `abort.percentage: { numerator: 33, denominator: HUNDRED }` and
   `retry_on: 5xx`, `num_retries: 2` on the route. Confirm the
   tail-success rate is near 100% (~67% × ~67% × ~67% = 30% of requests
   should fail all retries, but the route's chance to succeed each try
   is independent → ~70% × 70% × 70% = 35% lose; better than 33% bare).

2. **Per-vhost faults.** Apply `typed_per_filter_config` at the
   virtual_host level instead of per route. What does that change about
   how routes inherit / override it?

3. **gRPC abort.** Add a `/grpc-down` route with
   `abort: { grpc_status: 14, percentage: ... }` (UNAVAILABLE). With
   `grpcurl` or any gRPC client, verify the status code is honored as a
   trailer, not as the HTTP status.

4. **Runtime kill switch.** Set `abort.runtime_key: my_fault` and
   `percentage: { numerator: 0, denominator: HUNDRED }`. Use
   `curl -X POST 'localhost:9901/runtime_modify?my_fault=20'` to enable
   20% aborts without a reload. Set it back to `0` and watch traffic
   recover.

5. **Strip the headers at the edge.** Add
   `request_headers_to_remove: [x-envoy-fault-delay-request,
   x-envoy-fault-abort-request]` to the listener's catch-all virtual
   host. Verify external clients can no longer trigger faults via
   headers. Then move the fault filter to an *internal* listener and
   demonstrate that internal traffic still can.

## Cleanup

```bash
make down
```

## What's next

- **`09-tls-termination`** — downstream TLS, SNI selection, mTLS,
  and the passthrough variant. The first time we touch certificates.
