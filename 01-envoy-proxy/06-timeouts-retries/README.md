# 06 — Timeouts and retries

Two clusters, five routes, three backends + one deliberately-broken
`hello-bad`. Each route demonstrates one variation of timeout or retry
behaviour, so you can compare them side by side without restarting.

By the end of this example you should be able to answer:

- Where do the different timeouts live (connect, request, per-try, idle)?
- How does `per_try_timeout` interact with the route's overall `timeout`?
- What does `retry_on` accept, and which set is safe for which methods?
- Why does the `previous_hosts` predicate matter for the flaky-backend
  case?
- What does `retry_back_off` protect against in production?

## Prerequisites

- Done [`01`](../01-helloworld-static/) through [`05`](../05-health-checks/).
- Familiar with the `BREAK=true` knob added to
  [`apps/helloworld/`](../../apps/helloworld/) in example 05.
- Docker, `docker compose`, `curl`, `jq`.

## Run it

```bash
make up
make verify    # ~30 seconds; some steps intentionally wait for timeouts
make down
```

The verify script walks five scenarios and prints the wall-clock time
and HTTP status for each — that's the easiest way to see a timeout fire.

## Where timeouts live

Envoy has several distinct timeouts; mixing them up is one of the most
common debugging time-sinks. From the outside in:

| Timeout                                         | Scope                                                 | Default |
|-------------------------------------------------|-------------------------------------------------------|---------|
| `cluster.connect_timeout`                       | TCP / TLS handshake to upstream                       | 5s      |
| `cluster.upstream_connection_options.tcp_keepalive` | Keepalive on idle upstream connections             | OS      |
| `route.timeout`                                 | **Overall request** — first byte to last byte, including all retries | 15s |
| `route.retry_policy.per_try_timeout`            | Per attempt; resets on each retry                     | route.timeout if unset |
| `route.idle_timeout`                            | No bytes flowing in either direction                  | none    |
| `hcm.stream_idle_timeout`                       | Stream-level idle                                     | 5m      |
| `hcm.request_timeout`                           | HCM-level request timeout (request *receive*)         | none    |
| `hcm.drain_timeout`                             | During hot restart                                    | 5s      |

For day-to-day work, the two you'll set per-route are **`timeout`**
(overall budget) and **`per_try_timeout`** (per attempt).

### Rule of thumb

```
per_try_timeout * (num_retries + 1) + small slack  <=  route.timeout
```

If `timeout` is smaller, it preempts the retry budget. If it's much larger,
you lose the upper bound entirely.

## Walkthrough

### Route 1 — `/healthy` (control)

```yaml
- match: { prefix: "/healthy" }
  route:
    cluster: cluster_healthy
    regex_rewrite: { pattern: { regex: ".*" }, substitution: "/" }
```

No `timeout`, no `retry_policy`. Defaults apply: 15s overall, no retries.
Hits any of `hello-a`/`hello-b`/`hello-c`, returns 200 in milliseconds.

### Route 2 — `/strict` (timeout, no retry)

```yaml
- match: { prefix: "/strict" }
  route:
    cluster: cluster_healthy
    regex_rewrite: { pattern: { regex: ".*" }, substitution: "/slow" }
    timeout: 1s
```

`curl localhost:10000/strict?seconds=3` rewrites to backend `/slow` and
preserves the query string. Backend sleeps 3 seconds. Envoy gives up at
1 second and returns **`504 Gateway Timeout`** with `%RESPONSE_FLAGS%`
including `UT` (Upstream request Timeout).

> **Why preserve the query string?** `regex_rewrite` operates on the path
> component only — the query string passes through untouched. That lets
> us drive the backend's `/slow?seconds=N` without baking N into the
> route config.

### Route 3 — `/strict-retry` (timeout + retries)

```yaml
- match: { prefix: "/strict-retry" }
  route:
    cluster: cluster_healthy
    regex_rewrite: { pattern: { regex: ".*" }, substitution: "/slow" }
    timeout: 6s
    retry_policy:
      retry_on: "5xx,gateway-error,reset"
      num_retries: 2
      per_try_timeout: 1s
```

Same slow backend. Now `per_try_timeout: 1s` bounds each attempt; on
504, `retry_on: 5xx` triggers a retry; `num_retries: 2` means 2 retries
*after* the initial attempt (3 tries total); `timeout: 6s` gives the
whole thing room. Each try times out, so the final response is 504 after
~3 seconds. Counters bump on `cluster.cluster_healthy.upstream_rq_retry`.

### Route 4 — `/flaky` (no retry, mixed backends)

```yaml
- match: { prefix: "/flaky" }
  route: { cluster: cluster_flaky, regex_rewrite: { ... } }
```

`cluster_flaky` is `hello-a` + `hello-b` + `hello-bad`. With round robin
and no retry, ~1/3 of requests hit the broken endpoint and return 503.

### Route 5 — `/flaky-retry` (the fix)

```yaml
- match: { prefix: "/flaky-retry" }
  route:
    cluster: cluster_flaky
    regex_rewrite: { pattern: { regex: ".*" }, substitution: "/" }
    retry_policy:
      retry_on: "5xx"
      num_retries: 2
      retry_host_predicate:
        - name: envoy.retry_host_predicates.previous_hosts
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.retry.host.previous_hosts.v3.PreviousHostsPredicate
      host_selection_retry_max_attempts: 3
      retry_back_off:
        base_interval: 0.025s
        max_interval: 0.25s
```

Three things to notice:

1. **`retry_host_predicate: previous_hosts`** — refuse to retry the host
   that just failed. Without this, round-robin can hand the retry back
   to the same broken backend. `host_selection_retry_max_attempts: 3`
   limits how many host selections we'll try if the predicate keeps
   rejecting candidates (prevents pathological loops in tiny clusters).
2. **`retry_back_off`** — exponential backoff between attempts.
   `0.025s..0.25s` is the Envoy default; spelt out here for visibility.
   Without backoff, a thundering herd of clients all retrying together
   can turn a blip into a sustained overload (the "retry storm").
3. **`retry_on: 5xx`** — note we don't include `gateway-error,reset`
   here because the failure mode is a clean 503 from the backend, not a
   connection failure. If your real failures include reset/timeout,
   widen the list.

After retries, the success rate is essentially 100% and you'll see
`cluster.cluster_flaky.upstream_rq_retry_success` ~= 10 (the failed third
of 30 requests).

## `retry_on` values worth knowing

| Value                  | Trigger                                                        |
|------------------------|----------------------------------------------------------------|
| `5xx`                  | Any 5xx, including timeouts mapped to 504                      |
| `gateway-error`        | 502, 503, 504 only (subset of `5xx`)                           |
| `reset`                | Upstream TCP reset                                             |
| `connect-failure`      | Could not establish upstream connection                        |
| `refused-stream`       | HTTP/2 `REFUSED_STREAM`                                         |
| `retriable-status-codes`| Use `retriable_status_codes: [429]` for custom retriable codes |
| `retriable-headers`    | Retry only when the response carries a configured header       |
| `cancelled`            | gRPC `CANCELLED`                                                |
| `deadline-exceeded`    | gRPC `DEADLINE_EXCEEDED`                                        |
| `internal`             | gRPC `INTERNAL`                                                 |
| `resource-exhausted`   | gRPC `RESOURCE_EXHAUSTED`                                       |
| `unavailable`          | gRPC `UNAVAILABLE` (often the right baseline for gRPC)         |

Combine with commas: `retry_on: "5xx,reset,connect-failure"`.

## Method safety — Envoy is not idempotency-aware

Envoy retries based on `retry_on`, **not** on whether the HTTP method is
idempotent. If you `retry_on: 5xx` for a `POST /pay`, a 503 *after the
backend accepted the request* will be retried — possibly resulting in a
double charge.

Mitigations:

- **Per-route policies.** Mutating routes get conservative `retry_on`
  (e.g. only `connect-failure,refused-stream` — only retry when we know
  the upstream didn't process anything).
- **Idempotency keys** in the application protocol.
- **Retry budgets** (`retry_policy.retry_budget`) and per-route
  `num_retries` caps.

## Response flags reference

The default access log shows two-letter `%RESPONSE_FLAGS%`. The ones you
hit here:

| Flag  | Meaning                                                 |
|-------|---------------------------------------------------------|
| `UT`  | Upstream request Timeout — per_try or route timeout fired |
| `URX` | Upstream Retry limit eXceeded — num_retries was hit     |
| `UF`  | Upstream connection Failure                              |
| `UC`  | Upstream Connection terminated mid-request               |
| `(empty)` | Clean response                                       |

A final 504 after retries usually carries `UT` and/or `URX`.

## Stats worth knowing

Per-cluster counters that move during this example:

| Counter                                                   | Meaning |
|-----------------------------------------------------------|---------|
| `cluster.X.upstream_rq_total`                             | All requests *attempted*, including retries |
| `cluster.X.upstream_rq_2xx` / `_4xx` / `_5xx`             | Bucketed by status class |
| `cluster.X.upstream_rq_retry`                             | Number of retry attempts |
| `cluster.X.upstream_rq_retry_success`                     | Retries that succeeded |
| `cluster.X.upstream_rq_retry_overflow`                    | Retries refused due to budget / overflow |
| `cluster.X.upstream_rq_timeout`                           | Per-try timeouts (the `UT` flag) |
| `cluster.X.retry_or_shadow_abandoned`                     | Retry dropped because the downstream gave up |

```bash
curl -s 'localhost:9901/stats?filter=upstream_rq_retry'
watch -n1 "curl -s 'localhost:9901/stats?filter=cluster\\.cluster_flaky\\.upstream_rq'"
```

## Exercises

1. **Find the breaking point.** Lower `per_try_timeout` on `/strict-retry`
   from `1s` to `100ms` and re-run. What's the new total latency? Does
   `upstream_rq_timeout` increment three times or six?

2. **Add `retriable-status-codes`.** Configure `/flaky-retry` to also
   retry on 429:

   ```yaml
   retry_policy:
     retry_on: "5xx,retriable-status-codes"
     retriable_status_codes: [429]
   ```

   `make reload`, then `curl localhost:10000/flaky-retry/fail?code=429` —
   verify it retries (count rises) and eventually returns 200.

3. **Disable the predicate.** Comment out `retry_host_predicate` in
   `/flaky-retry` and observe what happens to success rate when retries
   land on the same broken backend.

4. **Constrain idle time.** Add `idle_timeout: 500ms` to the `/strict`
   route. What changes? When would `idle_timeout` matter more than
   `timeout` (hint: long-lived streaming or SSE responses)?

5. **The non-idempotent gotcha.** Add a route `/danger -> /echo` with
   `retry_on: 5xx, num_retries: 1`. Make `hello-bad` part of its cluster.
   POST to it: `curl -X POST -d 'pay=100' localhost:10000/danger`.
   How many times does the backend "see" the request when it lands on
   `hello-bad`? (Hint: check the access logs of all three healthy
   backends with `docker compose logs hello-a hello-b hello-c`.)

## Cleanup

```bash
make down
```

## What's next

- **`07-circuit-breakers`** — connection / pending / request caps and
  what happens at the limits. The other lever Envoy gives you to protect
  upstream.
