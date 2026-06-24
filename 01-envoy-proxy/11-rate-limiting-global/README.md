# 11 — Global rate limiting

Example 10's `local_ratelimit` was simple but local: each Envoy worker,
each Envoy replica, kept its own bucket. The **global rate limit** wires
Envoy to an external **rate-limit service** (Lyft's `envoyproxy/ratelimit`
binary) backed by **Redis**. Now the limit holds across every worker
and every replica, with one source of truth for the policy.

```
client ──▶ Envoy ──[gRPC]──▶ ratelimit-svc ──▶ Redis (counters)
              ▲                    │
              └── allow / deny ────┘
```

By the end of this example you should be able to answer:

- What's a *descriptor* and what's an *action*?
- How does Envoy talk to the rate-limit service — and what cluster
  config does that require?
- What does `failure_mode_deny` do and how should you set it?
- How do you express per-user, per-tier, per-IP, and compound limits?
- How do you read the policy YAML the service consumes?

## Prerequisites

- Done [`10-rate-limiting-local`](../10-rate-limiting-local/).
- Docker + `docker compose` with enough room for four containers.
- `curl`, `jq`.

## Run it

```bash
make up               # brings up hello, redis, ratelimit, envoy
make verify           # ~30s walk through six scenarios
make ratelimit-logs   # see what the RLS thinks about each call
make down
```

## The pieces

| Service     | What it does                                                          |
|-------------|-----------------------------------------------------------------------|
| `hello`     | Same backend as the other examples.                                   |
| `redis`     | Shared counters store. Every increment is atomic; TTL = window size.  |
| `ratelimit` | The gRPC rate-limit service. Reads `ratelimit-config/config.yaml`, consults Redis. |
| `envoy`     | The data plane. Calls the ratelimit service per request that has rate_limits. |

The four show up as separate containers; `docker compose ps` after
`make up` should list them all `Up`.

## Descriptors vs actions

Two halves of the same idea:

- An **action** lives on the Envoy *route* (or virtual host). It tells
  Envoy how to build a descriptor entry from this request:
  - `generic_key { descriptor_value: "default" }` → entry
    `(generic_key=default)`.
  - `request_headers { header_name: "x-user-id", descriptor_key: "user" }`
    → entry `(user=<the header value>)`.
  - `remote_address {}` → entry `(remote_address=1.2.3.4)`.
  - `header_value_match { ... }` → conditional entries.
- A **descriptor** lives in the ratelimit-service config. It's the
  expected key/value pattern, possibly nested, with a `rate_limit` at
  each leaf.

A request's actions produce a list of `(key=value)` pairs — the
*descriptor*. Envoy sends it to RLS. RLS walks its config tree, finds
the matching descriptor, increments Redis, and answers.

```yaml
# Envoy route
rate_limits:
  - actions:
      - generic_key: { descriptor_value: default }
  # ↓ produces descriptor: [(generic_key=default)]
```

```yaml
# ratelimit-config/config.yaml
descriptors:
  - key: generic_key
    value: default          # exact match
    rate_limit:
      unit: second
      requests_per_unit: 5
```

### Wildcard values (the killer feature)

Drop `value:` from a descriptor entry in the RLS config and **each
unique value gets its own counter**. That's the wildcard local rate
limit struggles with:

```yaml
descriptors:
  - key: user            # no value — wildcard
    rate_limit:
      unit: second
      requests_per_unit: 2
```

So `user=alice` and `user=bob` each have their own 2 req/s budget,
without enumerating users in the config.

### Compound descriptors

One action list = one descriptor with N entries. The RLS config can
nest them — match the first key, then the second.

```yaml
# Envoy: produces (user=alice, tier=premium)
rate_limits:
  - actions:
      - request_headers: { header_name: x-user-id, descriptor_key: user }
      - request_headers: { header_name: x-tier,    descriptor_key: tier }
```

```yaml
# RLS:
descriptors:
  - key: user
    descriptors:
      - key: tier
        value: premium
        rate_limit: { unit: second, requests_per_unit: 10 }
      - key: tier
        value: free
        rate_limit: { unit: second, requests_per_unit: 1 }
```

### Multiple independent descriptors

List multiple `rate_limits:` entries on the route to get *both* limits
applied — the request is denied if *any* of them is over:

```yaml
rate_limits:
  - actions: [ generic_key: { descriptor_value: "global" } ]   # one shared bucket
  - actions: [ request_headers: { header_name: x-user-id, descriptor_key: user } ]
```

## The Envoy side

```yaml
http_filters:
  - name: envoy.filters.http.ratelimit
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.ratelimit.v3.RateLimit
      domain: rl_demo
      failure_mode_deny: false
      timeout: 0.25s
      enable_x_ratelimit_headers: DRAFT_VERSION_03
      rate_limit_service:
        grpc_service:
          envoy_grpc: { cluster_name: ratelimit_cluster }
        transport_api_version: V3
```

Things to notice:

- **`domain: rl_demo`** must match the `domain:` field at the top of
  `ratelimit-config/config.yaml`. Different `domain` → RLS responds
  "unknown" and `failure_mode_deny` decides what happens.
- **`failure_mode_deny`** controls behavior when the RLS is
  unreachable, times out, or errors. `false` (fail open) lets traffic
  through — usually right for safety. `true` (fail closed) refuses
  everything — pick for sensitive endpoints where unmetered traffic is
  worse than no traffic.
- **`timeout`** — short. The RLS sits on the request hot path; a
  multi-hundred-ms timeout will tank your latency.
- **`enable_x_ratelimit_headers: DRAFT_VERSION_03`** — IETF-draft
  response headers (`x-ratelimit-limit / -remaining / -reset`) — see
  example 10 for details.

The cluster is the other half of "talk to the gRPC service":

```yaml
- name: ratelimit_cluster
  type: STRICT_DNS
  typed_extension_protocol_options:
    envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
      "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
      explicit_http_config:
        http2_protocol_options: {}
  load_assignment: ...
```

**You MUST enable HTTP/2** on the cluster — gRPC requires it. Skipping
this is the most common "rate limit doesn't work" cause. Without it
every request fails the RLS call and falls through `failure_mode_deny`.

## What the verify script demonstrates

| Step | URL / header                       | Behavior                                        |
|------|------------------------------------|-------------------------------------------------|
| 1    | `/free` × 10                       | No `rate_limits:` on the route → no RLS call.   |
| 2    | `/global` × 8 (rapid)              | 5 × 200, 3 × 429 from the shared `(generic_key=default)` bucket. |
| 3    | `/global` × 5 after 2s wait        | All 200 (window rolled).                        |
| 4    | `/per-user` × 4 with `x-user-id: alice` | 2 × 200, 2 × 429 (alice's bucket).         |
| 5    | `/per-user` × 4 with `x-user-id: bob`   | 2 × 200, 2 × 429 (bob has a SEPARATE bucket). |
| 6    | `/per-user` × 10 **without** the header | 10 × 200 — descriptor action drops, NO limit. |
| 7    | One `/global` → inspect `x-ratelimit-*` response headers |       |
| 8    | Envoy `ratelimit.*` stats          | per-filter counters                            |
| 9    | `cluster.ratelimit_cluster.*` stats| gRPC call volume                              |

Step 6 is the most important one to internalize: **if your action
references a field that isn't present on the request, the descriptor
is dropped, and the request is not rate-limited at all.** Defenses:

- Validate inputs at the edge.
- Add a fallback `generic_key` descriptor below the per-user one (multi
  `rate_limits:` entries, one applies to everyone, the other applies
  only when the header is present).
- Use the `header_value_match` action with an `expect_match` flag to
  produce a known descriptor when a condition fails.

## Operational notes

A few production concerns that don't show up in this single-host demo:

- **Sharing across replicas.** This is the headline feature. Scale
  Envoy with `docker compose up --scale envoy=3 -d` — every replica
  hits the same RLS + Redis, so the limit holds across all of them.
- **Redis sizing.** Counters are tiny (one Redis key per descriptor +
  window). For most setups a single small Redis is enough; for higher
  scale use Redis cluster mode and tell ratelimit via
  `REDIS_TYPE=cluster`.
- **RLS scaling.** The service is stateless — every request just round-
  trips to Redis. Scale horizontally; Envoy's gRPC client load-balances
  across all of them.
- **Latency budget.** A typical Redis call is sub-millisecond on the
  same network. Add Envoy's per-RTT overhead and budget ~2–5 ms for the
  whole filter. If your route's SLO is tight, consider local rate
  limit + global rate limit *together* (local catches the burst, global
  enforces the headline).
- **Watch for `over_limit` on healthy traffic.** That's the most
  common alert pattern. Spot a sudden jump in
  `cluster.ratelimit_cluster.upstream_rq_5xx` or
  `ratelimit.over_limit` and you've probably either hit a real abuse
  pattern, or set the policy too tight.

## Exercises

1. **Tiered limits.** Uncomment the hierarchical `key: user / key: tier`
   block in `ratelimit-config/config.yaml`. Add a `/tiered` route in
   `envoy.yaml` that produces `(user=X, tier=Y)` descriptors. Hit it
   with `x-tier: premium` and `x-tier: free` — note the different
   budgets. `make reload-rl` after changing the policy.

2. **Per-IP limits.** Add a route `/per-ip` using
   `remote_address: {}` as the action. Configure the RLS with
   `key: remote_address` wildcard. From two terminals (different
   source ports / docker bridges) confirm each gets its own bucket.

3. **Two Envoy replicas.** `docker compose up -d --scale envoy=2`
   (you'll have to remove the host port mapping from one or use a
   front load balancer — see the README in the parent folder). Verify
   that hitting either replica still hits the *same* global bucket.

4. **Failure-mode behavior.** `docker compose stop ratelimit`. Then
   `curl localhost:10000/global` — what happens with
   `failure_mode_deny: false`? Switch it to `true`, `make reload`, try
   again. Bring RLS back with `docker compose start ratelimit`.

5. **Inspect Redis live.**

   ```bash
   docker exec -it $(docker compose ps -q redis) redis-cli MONITOR
   ```

   Then trigger requests. You'll see the `INCR` and `EXPIRE` commands
   for each descriptor. Pause one of the counters with
   `redis-cli SET <key> 1000000` and watch the over-limit behaviour
   kick in immediately.

## Cleanup

```bash
make down
```

## What's next

- **`12-jwt-authn`** — the `jwt_authn` HTTP filter. Static JWKS, claim
  forwarding, header-driven JWT validation.
