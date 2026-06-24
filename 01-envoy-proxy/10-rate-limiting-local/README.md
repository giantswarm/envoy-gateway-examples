# 10 — Local rate limiting

The `local_ratelimit` HTTP filter — a token-bucket rate limiter that
runs **in-process** in each Envoy worker. No external service, no shared
state across replicas. Cheap, simple, and the right default for things
like:

- Per-route burst protection ("don't let one path swamp the cluster").
- Anti-abuse for endpoints that are expensive to serve.
- Defensive default in front of a service that doesn't have its own
  rate limit.

By the end of this example you should be able to answer:

- Where does the filter sit, and how do I opt routes in?
- What do `token_bucket`, `filter_enabled`, and `filter_enforced` do?
- How do per-worker buckets affect my math?
- How do I customize the over-limit response?
- When do I outgrow this and need the global rate limit service (example 11)?

## Prerequisites

- Done [`01`](../01-helloworld-static/) through
  [`09`](../09-tls-termination/).
- Familiar with the `typed_per_filter_config` pattern from
  [`08-fault-injection`](../08-fault-injection/).
- Docker, `docker compose`, `curl`, `jq`.

## Run it

```bash
make up
make verify        # ~15 seconds; includes refill waits between scenarios
make down
```

## Where it lives

```yaml
http_filters:
  - name: envoy.filters.http.local_ratelimit
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
      stat_prefix: rl_default
      # No token_bucket -> filter installed but a no-op globally.
      # Per-route overrides via typed_per_filter_config below.
  - name: envoy.filters.http.router
    ...
```

Same shape as the fault filter from example 08:

- Filter installed in the HCM chain (before `router`).
- Empty config = passthrough.
- Routes opt in by attaching their own `LocalRateLimit` under
  `typed_per_filter_config.envoy.filters.http.local_ratelimit`.

## The token bucket

```yaml
token_bucket:
  max_tokens: 5         # capacity (= burst)
  tokens_per_fill: 1    # tokens added each interval
  fill_interval: 1s     # how often refills happen
```

Semantics:

- Bucket starts **full** at `max_tokens`.
- Each request that goes through the filter consumes 1 token.
- A token is added every `fill_interval` until the bucket is back at
  `max_tokens`.
- A request with no token is rejected.

So `5 / 1 / 1s` = "5 burst, then sustained 1 req/s." `60 / 60 / 60s` = "60 burst, sustained 60 / minute, smoothed."

## `filter_enabled` vs `filter_enforced`

```yaml
filter_enabled:
  default_value: { numerator: 100, denominator: HUNDRED }
filter_enforced:
  default_value: { numerator: 100, denominator: HUNDRED }
```

Two independent probabilities:

| Probability        | Means                                                  | Counter           |
|--------------------|--------------------------------------------------------|-------------------|
| `filter_enabled`   | This fraction of requests is *sampled* by the filter   | `enabled`         |
| `filter_enforced`  | Of those, this fraction is *actually blocked* when over-limit | `enforced` |

Why two?

- **Observe-only mode:** `enabled=100, enforced=0`. Filter runs and
  increments `rate_limited` counters, but no request is actually blocked.
  Use this to canary a new policy before turning enforcement on.
- **Sample-only mode:** `enabled=10, enforced=100`. Only 10% of requests
  go through the filter at all; the rest skip the bucket. Useful if the
  filter is expensive and you want a representative sample.
- **Runtime keys:** both fields support a `runtime_key` so you can
  flip them via `POST /runtime_modify` without a reload — kill switch
  pattern.

## Customizing the over-limit response

```yaml
status:
  code: TooManyRequests        # default is 429
response_headers_to_add:
  - header: { key: retry-after, value: "1" }
  - header: { key: x-rate-limit-policy, value: "5 per second per envoy worker" }
```

`status.code` is an HTTP status enum (`TooManyRequests`, `ServiceUnavailable`,
`Forbidden`, …). The default — and the [RFC 6585](https://datatracker.ietf.org/doc/html/rfc6585#section-4)-correct one — is `429`.

The `enable_x_ratelimit_headers` option also makes Envoy add IETF-draft
headers to **every** response from the route (not just over-limit ones):

```
x-ratelimit-limit: 5
x-ratelimit-remaining: 3
x-ratelimit-reset: 2
```

Set it to `DRAFT_VERSION_03` to opt in. Off by default to avoid adding
headers that may not match the API contract.

## Per-worker buckets — the gotcha

Envoy starts `--concurrency` workers (one per CPU by default). **Each
worker has its own copy of the token bucket.** So if you set
`max_tokens: 100` and run with `--concurrency 4`, your effective cluster
rate is **4 × 100 = 400 tokens** — and round-robin/hashing across workers
means individual users may experience anywhere from 100 to 400
depending on which worker handles their connections.

Our `docker-compose.yml` forces `--concurrency 1` so the math is
predictable for the demo. In production with `--concurrency 4`, you'd
either:

1. **Divide** your target by worker count (`max_tokens: 25` for a
   nominal "100/s") — works, but pessimistic when load is unbalanced.
2. **Use `local_rate_limit_per_downstream_connection: true`** — bucket
   per-connection, predictable but doesn't help with "per-user".
3. **Use the global rate limit service** (example 11) — one external
   counter, shared by every worker and every Envoy replica.

## Per-route descriptors (preview)

You can scope the bucket to a key like `x-user-id`, so each user gets
their own quota:

```yaml
descriptors:
  - entries:
      - key: user
        value: alice
    token_bucket:
      max_tokens: 5
      tokens_per_fill: 5
      fill_interval: 1s
rate_limits:
  - actions:
      - request_headers:
          header_name: "x-user-id"
          descriptor_key: "user"
```

Limitation: the `descriptors[].entries[].value` must match exactly. To
get a separate bucket per *unique* value, you can use multiple
descriptors or rely on the global rate limit service which supports
wildcard descriptors.

See Exercise 1.

## What the verify script does

| Step | URL                  | Behavior                                            |
|------|----------------------|-----------------------------------------------------|
| 1    | `/free` × 10         | All 200 — no limit attached                         |
| 2    | `/limited` × 8       | 5 × 200, 3 × 429 (default over-limit status)        |
| 3    | wait 4 s, `/limited` × 3 | All 200 — bucket refilled ~4 tokens during sleep |
| 4    | `/limited` × 1       | Inspect `x-ratelimit-*` response headers            |
| 5    | `/limited-custom` × 6 | 5 × 200, then a 503 with `retry-after: 1`          |
| 6    | `/stats?filter=http_local_rate_limit` | `enabled`, `ok`, `rate_limited`, `enforced` per stat_prefix |

The stats live under the filter's `stat_prefix`. With per-route
overrides each has its own prefix:

```
limited.http_local_rate_limit.enabled
limited.http_local_rate_limit.ok
limited.http_local_rate_limit.rate_limited
limited.http_local_rate_limit.enforced
limited_custom.http_local_rate_limit.enabled
... etc
```

## Exercises

1. **Per-user via descriptors.** Add a route `/per-user` with a
   per-user descriptor:

   ```yaml
   typed_per_filter_config:
     envoy.filters.http.local_ratelimit:
       "@type": ...
       stat_prefix: per_user
       token_bucket: { max_tokens: 100, tokens_per_fill: 100, fill_interval: 1s }
       descriptors:
         - entries: [ { key: user, value: alice } ]
           token_bucket: { max_tokens: 3, tokens_per_fill: 3, fill_interval: 1s }
         - entries: [ { key: user, value: bob } ]
           token_bucket: { max_tokens: 3, tokens_per_fill: 3, fill_interval: 1s }
       rate_limits:
         - actions:
             - request_headers:
                 header_name: "x-user-id"
                 descriptor_key: "user"
       filter_enabled: { default_value: { numerator: 100, denominator: HUNDRED } }
       filter_enforced: { default_value: { numerator: 100, denominator: HUNDRED } }
   ```

   Verify: `for i in 1 2 3 4; do curl -H 'x-user-id: alice' .../per-user; done`
   — first 3 succeed, 4th gets 429. `bob` still has full budget.

2. **Observe-only canary.** Set `filter_enforced.default_value.numerator: 0`
   on `/limited`, `make reload`, then hit it 20 times in a row. All
   requests should succeed *but* `limited.http_local_rate_limit.rate_limited`
   should still increment. Use this pattern to validate a policy before
   enforcement.

3. **Runtime kill switch.** Add `runtime_key: rl_limited_enabled` to
   `filter_enabled`. Then:

   ```bash
   curl -X POST 'localhost:9901/runtime_modify?rl_limited_enabled=0'
   # filter is now off without a reload
   curl -X POST 'localhost:9901/runtime_modify?rl_limited_enabled=100'
   # back on
   ```

4. **Higher concurrency.** Remove `--concurrency 1` from
   `docker-compose.yml` (let Envoy use one worker per CPU), `make down
   && make up`, re-run step 2. How do the numbers change? Why?

5. **Vhost-scoped limit.** Move the `/limited` config from the route
   level to the virtual host's `typed_per_filter_config`. How does that
   affect the `/free` route? (Hint: route-level configs override vhost
   configs, but absent route configs inherit from vhost.)

## When to outgrow this

You want example 11 (global rate limit) when:

- Sharing the limit across multiple Envoy replicas behind a load
  balancer.
- Per-API-key / per-tenant quotas that survive Envoy restarts.
- Need richer rate-limit logic (custom descriptors, complex actions,
  pricing tiers).
- Want a single source of truth for the policy.

## Cleanup

```bash
make down
```

## What's next

- **`11-rate-limiting-global`** — same idea but with a shared external
  rate-limit service (Envoy's `ratelimit` + Redis), so the limit holds
  across Envoy replicas.
