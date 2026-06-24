# 04 — Load balancing

Three identical helloworld replicas (`hello-a`, `hello-b`, `hello-c`) behind
**three clusters** that share the same endpoint set but apply different
load-balancing policies. The route table sends each demo path to the
matching cluster:

| Path  | Cluster      | LB policy        |
|-------|--------------|------------------|
| `/rr` | `cluster_rr` | `ROUND_ROBIN`    |
| `/lr` | `cluster_lr` | `LEAST_REQUEST`  |
| `/rh` | `cluster_rh` | `RING_HASH` (hash on `x-user-id`) |

By the end of this example you should be able to answer:

- Where does load balancing happen in Envoy's request pipeline?
- What's the difference between `ROUND_ROBIN`, `LEAST_REQUEST`, `RANDOM`,
  `RING_HASH`, and `MAGLEV`?
- When should I use consistent hashing? What's `hash_policy`?
- Why does `LEAST_REQUEST` look like random under low load?
- How do I confirm distribution from `/stats` and `/clusters`?

## Prerequisites

- Done [`01`](../01-helloworld-static/) through [`03`](../03-routing-basics/).
- Docker, `docker compose`, `curl`, `jq`. Optional: `hey` or `vegeta` for
  the concurrency exercises.

## Run it

```bash
make up
make verify
make down
```

`make verify` does the round-robin and ring-hash demos and prints
per-cluster `upstream_rq_total` counters.

## Where LB lives in the pipeline

Recall from [`03`](../03-routing-basics/) the matching pipeline ends at:

```
action -> route { cluster: ..., ... }
```

Once the route picks a cluster, **the cluster's `lb_policy` decides which
endpoint inside that cluster gets the request.** Load balancing is a
property of the cluster, not the route. That's why the same three
backends below can serve under three different policies just by being
referenced from three different clusters.

```
HTTP request -> match a route -> route picks a cluster -> cluster's
lb_policy picks an endpoint -> request forwarded.
```

## The policies

### `ROUND_ROBIN`

Walks the endpoint list in order. Simple, deterministic, predictable.
**Default when you don't specify `lb_policy`.** Use when:

- All endpoints are roughly equally provisioned.
- Per-request cost is similar.
- You want even distribution and don't care about stickiness.

```yaml
lb_policy: ROUND_ROBIN
```

### `LEAST_REQUEST`

Picks the endpoint with the fewest in-flight requests. Implementation
detail: it doesn't scan all endpoints — that'd be O(N) per request. It
uses **Power of Two Choices** (P2C): pick `choice_count` endpoints at
random, send to the least-busy of those. `choice_count` defaults to `2`;
2 is provably almost as good as scanning all for surprisingly little
cost.

```yaml
lb_policy: LEAST_REQUEST
least_request_lb_config:
  choice_count: 2
```

Best when:

- Per-request cost varies a lot (some endpoints "stuck" on slow requests).
- You want to drain naturally from a slow endpoint without active health
  checks.
- Weighted load balancing — `least_request_lb_config` also supports
  `active_request_bias` for endpoint-weight-aware behaviour.

> **Why it looks random under low load.** With no contention, all
> endpoints have 0 in-flight requests when LB runs. P2C picks two at
> random, both have 0 in-flight, and ties are broken randomly. So sequential
> traffic looks like random pick of 2 — close to uniform, but not as flat
> as round-robin.

### `RING_HASH` (and `MAGLEV`)

Consistent hashing. The endpoints are placed on a ring (or a permutation
table for Maglev); each request's hash key picks a point on the ring;
the closest endpoint serves. Adding/removing one endpoint moves only
**1/N** of the traffic.

Use when:

- You want **stickiness** — same user / cache key / shard ID always lands
  on the same endpoint.
- The backends maintain per-key state and a remap would be expensive
  (warm in-memory caches, sticky WebSocket sessions, sharded stores).

```yaml
lb_policy: RING_HASH
ring_hash_lb_config:
  minimum_ring_size: 1024
  maximum_ring_size: 8192
```

A ring with no input is useless — you must declare a `hash_policy` on the
**route** (not the cluster) so Envoy knows what to hash:

```yaml
- match: { prefix: "/rh" }
  route:
    cluster: cluster_rh
    hash_policy:
      - header: { header_name: "x-user-id" }
      # alternatives:
      # - cookie: { name: "sid", ttl: 0s }
      # - query_parameter: { name: "shard" }
      # - connection_properties: { source_ip: true }
      # - filter_state: { key: "..." }
```

If the hash input is missing (e.g. `/rh` without `x-user-id`), the
fallback is random — useful to confirm in `verify.sh` step 3.

`MAGLEV` is similar but uses a fixed-size lookup table (~65537 entries)
and has tighter balance properties; it costs a touch more memory but
gives you a much flatter distribution than `RING_HASH`. Use it when
`RING_HASH` distribution is too uneven.

### `RANDOM`

Picks any endpoint uniformly at random. Cheaper than round-robin (no
shared state) but variance is higher. Fine for very-high-throughput
load balancers where the rounding error doesn't matter.

### `MAGLEV`, `ORIGINAL_DST_LB`, `CLUSTER_PROVIDED`

Other policies you'll see — covered briefly:

- `MAGLEV` — see above.
- `ORIGINAL_DST_LB` — paired with `type: ORIGINAL_DST` clusters; the
  destination is taken from the connection's original target (used for
  transparent proxying like Istio's mesh inbound).
- `CLUSTER_PROVIDED` — defer to an extension. The future-proof way to
  attach pluggable LB algorithms.

> **API note.** Recent Envoy versions prefer the newer
> `load_balancing_policy:` extension field over the top-level
> `lb_policy:` enum. The enum still works and is what you'll see most
> often; we use it here for readability.

## Verifying distribution

Three places to look:

1. **The response body.** Our helloworld backends echo `from_=$NAME`, so
   `jq -r .from_` over a curl loop is the cheapest check.

   ```bash
   for i in $(seq 1 30); do curl -s localhost:10000/rr | jq -r .from_; done \
     | sort | uniq -c
   ```

2. **Per-cluster stats.** `cluster.<name>.upstream_rq_total` increments
   on every request sent to that cluster.

   ```bash
   curl -s 'localhost:9901/stats?filter=cluster\.cluster_rr\.upstream_rq_total'
   ```

3. **Per-endpoint stats.** `/clusters` (text or `?format=json`) shows each
   endpoint with its in-flight (`rq_active`), totals (`rq_total`), error
   counters, and last health-check time.

   ```bash
   curl -s 'localhost:9901/clusters?cluster=cluster_rr' \
     | grep -E '(::cx_active|::rq_total|hostname)'
   ```

## Watching ring-hash do its thing

`verify.sh` step 2 runs the same 6 users 3 times and prints the mapping
each round. You should see:

```
--- run 1 ---
  alice  -> hello-c
  bob    -> hello-a
  carol  -> hello-c
  dave   -> hello-b
  eve    -> hello-a
  frank  -> hello-c
--- run 2 ---
  alice  -> hello-c        # same
  bob    -> hello-a        # same
  ...
```

The mapping is stable. Step 3 omits the `x-user-id` header — without the
hash input, distribution falls back to random across the ring's segments,
so the counts will be roughly even.

## Exercises

1. **Switch policies in place.** Edit `envoy.yaml`, change
   `cluster_rr`'s `lb_policy` to `RANDOM`, then `make reload`. Re-run
   the 30-request `/rr` loop. How does the distribution compare? Why is
   it close to but not exactly 10/10/10?

2. **Hash on a query parameter.** Change route `/rh`'s `hash_policy`
   from `header: x-user-id` to:

   ```yaml
   hash_policy:
     - query_parameter: { name: "shard" }
   ```

   Verify with `curl 'localhost:10000/rh?shard=42'` — the same `shard`
   value should always hit the same endpoint.

3. **Stickiness under endpoint churn.** While `verify.sh` step 2 is
   running, stop one backend mid-test:

   ```bash
   docker compose stop hello-b
   ```

   Re-run the loop. How many of the 6 users moved to a different endpoint?
   (Expected: only the ones previously mapped to `hello-b`, roughly 1/3.)
   Restart it and check again.

4. **Drive `LEAST_REQUEST` under contention.** With [`hey`](https://github.com/rakyll/hey)
   or `vegeta` installed:

   ```bash
   # Slow some backends on purpose — block one with /slow on a long delay,
   # then drive concurrent traffic via /lr. The least-busy backends should
   # absorb most of it.
   ( for i in $(seq 1 5); do curl -s "localhost:10000/lr/slow?seconds=20" & done )
   hey -c 20 -n 200 http://localhost:10000/lr
   curl -s 'localhost:9901/clusters?cluster=cluster_lr' \
     | grep -E 'hostname|rq_total|rq_active'
   ```

   (You'll need to add a route mapping `/lr/slow*` → backend `/slow` for
   this exercise — it's a small addition.)

5. **Compare ring sizes.** Drop `cluster_rh`'s `minimum_ring_size` from
   `1024` to `64` and re-run the 30-user demo. Does the distribution get
   noticeably less even? Try Maglev (`lb_policy: MAGLEV`) and compare.

## Cleanup

```bash
make down
```

## What's next

- **`05-health-checks`** — active health checks + outlier detection.
  Kill a backend in flight and watch traffic drain.
