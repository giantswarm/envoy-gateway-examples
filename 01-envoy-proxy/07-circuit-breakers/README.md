# 07 — Circuit breakers

One backend, one cluster, very tight thresholds. We send 15 concurrent
slow requests and watch the breakers reject most of them. Different
problem from example 05 ([outlier detection](../05-health-checks/)) and
example 06 ([retries](../06-timeouts-retries/)): outlier detection ejects
endpoints that *are* misbehaving; circuit breakers prevent endpoints
that are *fine* from being overwhelmed.

By the end of this example you should be able to answer:

- Which five thresholds matter, and what does each cap?
- How do `max_connections` and `max_requests` differ on HTTP/1.1 vs HTTP/2?
- What does a tripped breaker look like (status, header, log flag, stats)?
- What is `track_remaining` for?
- How do priorities (`DEFAULT` vs `HIGH`) let you reserve headroom for
  important traffic?

## Prerequisites

- Done [`01`](../01-helloworld-static/) through [`06`](../06-timeouts-retries/).
- Docker, `docker compose`, `curl`, `jq`.

## Run it

```bash
make up
make verify        # ~7 seconds; bursts 15 concurrent slow requests
make burst N=25    # replay the burst manually with a different size
make watch         # live counters
make down
```

## The five thresholds

Circuit breakers live on the **cluster**, under
`circuit_breakers.thresholds[]`. Each entry is per-`priority` (the
default priority is `DEFAULT`; routes can mark themselves `HIGH`).

```yaml
circuit_breakers:
  thresholds:
    - priority: DEFAULT
      max_connections: 3
      max_pending_requests: 2
      max_requests: 3
      max_retries: 1
      track_remaining: true
```

| Threshold              | Caps                                            | Default |
|------------------------|-------------------------------------------------|--------:|
| `max_connections`      | Open upstream TCP connections                   | 1024    |
| `max_pending_requests` | Requests waiting for a connection / HTTP/2 stream | 1024  |
| `max_requests`         | In-flight HTTP requests (mostly relevant for HTTP/2 multiplexing) | 1024 |
| `max_retries`          | Concurrent retries across the whole cluster     | 3       |
| `max_connection_pools` | Distinct connection pools per host              | unlimited |

The defaults are intentionally enormous — Envoy ships with breakers
**off in practice** unless you turn them down. That's the right call:
unset defaults shouldn't refuse traffic.

### HTTP/1.1 vs HTTP/2

For an HTTP/1.1 backend (our Flask app), each in-flight request needs
its own connection. So `max_connections` ≈ `max_requests` and the smaller
of the two wins — both at 3 here.

For an HTTP/2 backend, one TCP connection can carry many concurrent
streams. There you tune `max_connections` to control pool size and
`max_requests` to control in-flight stream count.

### What about `max_retries`?

This is the **concurrent** retry cap, not the per-request `num_retries`
from example 06. Separate counter so a retry storm can't blow past your
in-flight cap. Default 3 is low for production; if your retry rate
spikes, you'll see retries rejected with their own overflow counter
(`upstream_rq_retry_overflow`).

## What a tripped breaker looks like

When a threshold rejects a request, the client sees:

- **`503 Service Unavailable`**
- A response header **`x-envoy-overloaded: true`**
- Access log shows **`%RESPONSE_FLAGS%`** containing **`UO`** (Upstream
  Overflow)
- Per-cluster stats increment one of:
  - `upstream_cx_overflow` — max_connections breached
  - `upstream_rq_pending_overflow` — max_pending_requests breached
  - `upstream_rq_overflow` — max_requests breached
  - `upstream_rq_retry_overflow` — max_retries breached

The 503 happens **before** any retry policy fires — overflowed requests
do not retry locally.

## The `track_remaining` gauges

```yaml
circuit_breakers:
  thresholds:
    - track_remaining: true
```

Adds gauges so you can graph headroom:

```
cluster.cluster_slow.circuit_breakers.default.cx_open           # 1 when max_connections breached
cluster.cluster_slow.circuit_breakers.default.rq_pending_open   # 1 when pending queue full
cluster.cluster_slow.circuit_breakers.default.rq_open           # 1 when max_requests breached
cluster.cluster_slow.circuit_breakers.default.rq_retry_open     # 1 when max_retries breached
cluster.cluster_slow.circuit_breakers.default.remaining_cx
cluster.cluster_slow.circuit_breakers.default.remaining_pending
cluster.cluster_slow.circuit_breakers.default.remaining_rq
cluster.cluster_slow.circuit_breakers.default.remaining_retries
```

The `*_open` gauges flip to 1 the moment the limit is hit and back to 0
when capacity returns. `remaining_*` is "current headroom". Plot both
together — the `_open` gauge tells you *when* you saturated; `remaining_*`
tells you how much room you usually have.

## Priorities — reserving headroom for important traffic

Routes can carry a `priority`:

```yaml
- match:
    prefix: "/critical"
  route:
    cluster: cluster_slow
    priority: HIGH
```

The cluster then declares separate thresholds for each priority:

```yaml
circuit_breakers:
  thresholds:
    - priority: DEFAULT
      max_requests: 50
    - priority: HIGH
      max_requests: 100      # different (larger) budget reserved for /critical
```

Useful when you want a small `/health` or `/auth` route to always have
capacity even when the firehose is saturated.

## Sizing thresholds in practice

Three rules of thumb that catch most cases:

1. **Start from upstream capacity, not from traffic.** Pick limits at
   roughly 80% of what the upstream can sustain. Breaking *early* is
   the point — once you're at 100% you've already crossed the cliff.
2. **`max_pending_requests` should be small.** A deep queue trades 503
   for high tail latency; a shallow queue gives clients a fast NO and
   lets them retry against a different replica.
3. **Combine with retries thoughtfully.** A tripped breaker returns 503,
   which `retry_on: 5xx` will retry. With `previous_hosts` predicate (
   example 06) the retry lands on a different host; without it, you can
   amplify a hot-spot. Watch `upstream_rq_retry_overflow`.

## How the verify script tests this

15 curls fire simultaneously. With `max_connections=3` and
`max_pending_requests=2`:

```
   t=0s    15 requests arrive at Envoy
           3 grab connections, hit backend (sleeps 3s)
           2 queue as pending
          10 overflow -> 503/UO with x-envoy-overloaded: true

   t=3s    First 3 responses come back, slots free
           2 pending promoted to active (also sleep 3s)

   t=6s    Last 2 responses come back
```

Final tally: 5 × 200 + 10 × 503, total runtime ~6 s.

If your run looks different:

- **All 200**: backend completed faster than the burst could fire. Use
  `make burst N=30 SECONDS=5`.
- **Fewer than 5 successes**: the bash backgrounding wasn't fast enough
  and some "5 successes" got rejected too. Pre-warm the connection pool
  with one request, then burst.
- **No 503s but slow responses**: probably the Flask dev server fell
  back to single-threaded mode. Verify with `docker compose logs hello`.

## Exercises

1. **Loosen the limits.** Set `max_connections: 10`, `max_pending_requests:
   20`, `max_requests: 10`. `make reload`, `make burst N=15`. Should see
   0 overflows now. What's the trade-off in production?

2. **Watch the gauges live.** In one terminal: `make watch`. In
   another: `make burst N=25`. Watch `*_open` flip to 1 and back, and
   `remaining_*` drop.

3. **Two priorities.** Add a `/critical` route with `priority: HIGH` and
   give HIGH a generous `max_requests: 10` budget while leaving DEFAULT
   at 3. Burst `/?seconds=3` and `/critical?seconds=3` at the same time
   — the critical path should keep flowing.

4. **Pending vs. requests.** Set `max_pending_requests: 0` and
   `max_requests: 5`. Burst N=15. How does the tally and the breakdown
   of overflow counters change? Hint: with zero pending, every burst
   above `max_requests` is *immediate* 503.

5. **Mix with retries.** Add a retry policy to the route
   (`retry_on: 5xx`, `num_retries: 2`). Burst again. Does the success
   rate go up or down? Look at `upstream_rq_retry_overflow`.

## Cleanup

```bash
make down
```

## What's next

- **`08-fault-injection`** — the inverse: make Envoy *cause* failures
  intentionally so you can test how your clients behave when they hit
  the breakers and timeouts above.
