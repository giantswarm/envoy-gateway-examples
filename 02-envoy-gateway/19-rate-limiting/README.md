# 19 — Rate limiting (local) via BackendTrafficPolicy

Phase 2's tenant-shaped answer to [Phase 1 example 11](../../01-envoy-proxy/11-rate-limiting-global/).
EG exposes Envoy's rate limit through `BackendTrafficPolicy.rateLimit`
in two flavors: **Local** (per-pod token buckets) and **Global**
(cluster-wide via Envoy's external ratelimit service + Redis).

This example uses **Local** — no extra infrastructure, easiest to
deploy. The README sketches the Global config; pick that mode when
you have many replicas and need precise budgets.

We wire up three buckets distinguished by an `x-tenant:` header:

| Header             | Limit         |
|---------------------|---------------|
| `x-tenant: free`   | **5 / minute**|
| `x-tenant: premium`| **100 / minute** |
| no header (catch-all)| **10 / minute**|

By the end you should be able to answer:

- What's the difference between Local and Global rate limit?
- How do `clientSelectors` work, and what's the matching order?
- What's the per-pod-vs-cluster tradeoff in Local mode?
- What does Envoy return when the budget is exhausted?
- Where does the token bucket live in the generated config?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–18.

## Run it

```bash
make up           # Gateway + HTTPRoute + BTP (with rateLimit.local)
make verify       # hammers each bucket; asserts the cutoff fires
make admin
make down
```

## Local vs Global

| Aspect                | Local                                      | Global                                                          |
|-----------------------|---------------------------------------------|------------------------------------------------------------------|
| Token buckets live in | Each Envoy pod (separately)                 | A central ratelimit service backed by Redis                      |
| Aggregation           | None — N pods × M/min = N × M/min worst case| Cluster-wide; precise                                            |
| Extra infrastructure  | None                                        | Deploy [`envoyproxy/ratelimit`](https://github.com/envoyproxy/ratelimit) + Redis, plus `rateLimit` block in EnvoyGateway controller config |
| Failure mode          | Self-contained; no extra failure surface    | Ratelimit service / Redis down — depending on `failClosed`       |
| Best fit              | Single-replica gateways, dev/test, ample headroom | Multi-replica production gateways with strict per-tenant budgets |
| Phase mapping         | This example                                | Phase 1 ex 11 (raw Envoy); EG Global is the modern wrap          |

The rule of thumb: **Local is fine until you can't be off by N×
replicas**. Then move to Global.

## How matching works in Local

```yaml
local:
  rules:
    - clientSelectors:
        - headers:
            - name: x-tenant
              value: free       # exact (string match by default)
      limit: { requests: 5, unit: Minute }
    - clientSelectors:
        - headers:
            - name: x-tenant
              value: premium
      limit: { requests: 100, unit: Minute }
    - limit: { requests: 10, unit: Minute }   # no selectors = catch-all
```

Rules are evaluated **in order**. The first rule whose
`clientSelectors` matches the request wins. A rule with NO
`clientSelectors` is the catch-all — it should be the LAST entry
(otherwise it shadows everything).

Selectors support:

| Selector            | Matches against                                |
|---------------------|------------------------------------------------|
| `headers[]`         | Request headers (exact / regex / prefix)        |
| `sourceCIDR`        | The (post-XFF) client IP                        |
| `headers + sourceCIDR` | AND of both                                  |

So you can express things like "free-tier users from US west" by
combining a header + CIDR rule.

## Limit unit

```yaml
limit:
  requests: 5
  unit: Second | Minute | Hour | Day
```

Pick the unit that matches the burstiness of your API:
- Per-second works for steady RPS shaping.
- Per-minute is the common "tenant quota" choice (this example).
- Per-hour / per-day are billing-style budgets.

## What a 429 looks like

Envoy generates a 429 with body `local_rate_limited` by default.
Set `rateLimit.local.body:` to override. The status code itself is
not configurable.

```http
HTTP/1.1 429 Too Many Requests
content-length: 18
x-envoy-ratelimited: true
content-type: text/plain

local_rate_limited
```

Section 6 of `make verify` prints the live response.

## Sketch: Global mode

Doesn't run in this example, but worth knowing the shape:

```yaml
# 1. The BTP — same shape, just `type: Global`:
spec:
  rateLimit:
    type: Global
    global:
      rules:
        - clientSelectors: [ ... ]
          limit: { requests: 1000, unit: Minute }

# 2. EnvoyGateway controller config — enable the global service:
config:
  envoyGateway:
    rateLimit:
      backend:
        type: Redis
        redis:
          url: redis-master.demo.svc.cluster.local:6379
```

Plus a deployment of `envoyproxy/ratelimit:master` + Redis (Phase 1
ex 11 has the Docker-Compose version). EG provisions the right
filter; the descriptors flow over gRPC to that service.

## The pieces

```
manifests/
├── gateway.yaml
├── httproute.yaml
└── backendtrafficpolicy.yaml   # type: Local + 3 rules
```

## Verify

`make verify` runs 7 sections:

1. CRs Accepted.
2. Port-forward.
3. **Free tenant** burst of 8 → expects 5 × 200, 3 × 429.
4. **Premium tenant** burst of 8 → expects 8 × 200.
5. **Catch-all** burst of 13 → expects 10 × 200, 3 × 429.
6. Inspect the 429 response headers + body.
7. `/config_dump`: find `envoy.filters.http.local_ratelimit`,
   confirm per-route attachment.

The script is deterministic for the first run after `make up`
(buckets are fresh). If you re-run within a minute, the existing
buckets are still partially consumed — wait 60s for a full reset.

## Common failure modes

| Symptom                                                                | Cause                                                                                                          |
|-------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| All requests get 429 immediately                                         | Catch-all rule with a tiny limit listed FIRST (shadowing the per-tenant rules). Reorder.                       |
| `x-tenant: free` gets the catch-all limit, not the free limit            | Header name mismatch (case-sensitive value), OR the rule order puts catch-all before the specific one.        |
| Re-running verify gives intermittent results                            | Buckets are per-minute; consumed tokens haven't refilled. Wait 60s OR change the limit's `unit:` to Second.    |
| With multiple Envoy replicas, effective limit is N× the configured       | This is Local-mode design. Replicas don't coordinate. Switch to Global.                                       |
| `429` body shows "local_rate_limited" — want JSON instead                | Set `rateLimit.local.body:` to a JSON string. (Status code stays 429.)                                         |
| BTP `Accepted=False reason: Invalid`                                    | `rateLimit.type` mismatched with the block name (`type: Local` but populated `global:` block, or vice versa). |

## Exercises

1. **Per-IP rate limit.** Add a `sourceCIDR:` selector that
   matches `0.0.0.0/0` and limits to 30/minute. Combine with the
   ClientTrafficPolicy from example 11 so the IP is taken from
   `X-Forwarded-For`. Confirm two different XFF values get
   independent quotas.

2. **Per-second smoothing.** Change one rule's `unit:` to
   `Second`. Send burst traffic and observe the response: the
   token bucket refills 1/s, so steady ≤1 RPS works, 2 RPS gets
   throttled.

3. **JSON body.** Set `rateLimit.local.body:` to
   `'{"error":"rate limited","retry_after":60}'`. Hit the
   exhausted bucket, confirm the body.

4. **Combine with extAuth.** Stack the rate limit BTP with
   example 16's extAuth SecurityPolicy on the same HTTPRoute.
   Which filter runs first? (Hint: HCM filter ordering — rate
   limit is upstream-side, extAuth is downstream auth.)

5. **Switch to Global.** Deploy [`envoyproxy/ratelimit`](https://github.com/envoyproxy/ratelimit)
   + Redis, edit the EnvoyGateway config to point at the service,
   change `type: Local` to `Global`. Verify the limits now apply
   cluster-wide by hitting two different Envoy pods (use
   `make pf` against specific pod names) and confirming the
   counter is shared.

## Cleanup

```bash
make down
```

## What's next

- [`20-httproutefilter`](../20-httproutefilter/) — the
  `HTTPRouteFilter` CR for capture-group rewrites and other
  features plain HTTPRoute filters can't express.
