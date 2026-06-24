# 12 — BackendTrafficPolicy: retries, timeouts, LB, health checks

`BackendTrafficPolicy` is the EG CR for **everything-about-how-Envoy-
treats-the-upstream**. It maps onto the entire range of resiliency
features Phase 1 examples 04–07 covered in raw Envoy YAML:

| Phase 1 example                       | BTP field                                       |
|----------------------------------------|--------------------------------------------------|
| `04-load-balancing` (RR / LR / RH)     | `loadBalancer.type` + `consistentHash`           |
| `05-health-checks` (active probes)     | `healthCheck.active`                             |
| `05-health-checks` (outlier detection) | `healthCheck.passive`                            |
| `06-timeouts-retries`                  | `timeout.http`, `retry`                          |
| `07-circuit-breakers`                  | `circuitBreaker`                                 |
| `08-fault-injection`                   | `faultInjection.delay` / `.abort` (not exercised here) |

This example wires up **five** of those features at once and shows
both behavioral evidence (retry + timeout) and generated-config
evidence (LB type, active HC, outlier detection).

By the end you should be able to answer:

- How does `BackendTrafficPolicy` relate to `ClientTrafficPolicy`
  (example 11)? What's the split rule?
- What's the practical difference between `retry.retryOn.triggers`
  and `retry.retryOn.httpStatusCodes`?
- How does `requestTimeout` interact with `perRetry.timeout`?
- What's the difference between **active** health checks and
  **passive** outlier detection?
- Where does each BTP field show up in the generated Envoy config?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–11.

## Run it

```bash
make up           # Gateway + HTTPRoute + BTP
make verify       # 6-section walkthrough
make admin
make down
```

## Attachment

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute              # or Gateway / GRPCRoute / TCPRoute / UDPRoute / TLSRoute
      name: tuned-backend
      # sectionName: <rule-name>   # optional — limit to one rule
```

- BTP **only attaches to Gateway-API resources**, NOT directly to
  Services. Don't confuse it with **`BackendTLSPolicy`** (example
  10) which *does* target Services. Targeting a Service here gives:
  > `Invalid value: this policy can only have a targetRefs[*].kind of Gateway/HTTPRoute/GRPCRoute/TCPRoute/UDPRoute/TLSRoute`
- Valid `kind:` values: `Gateway`, `HTTPRoute`, `GRPCRoute`,
  `TCPRoute`, `UDPRoute`, `TLSRoute`. The `group:` must be
  `gateway.networking.k8s.io`.
- **Route-level vs Gateway-level**: attaching to an HTTPRoute means
  the policy applies to traffic flowing through THAT route. Attach
  to a Gateway and the policy applies to every route on it (unless
  a route-level BTP overrides — same "specific wins" rule as CTP).
- One BTP per **(target, sectionName)** slot. Conflicting policies
  flip to `Conflicted=True`.
- `targetRefs` is an array — one BTP can target multiple routes
  with the same settings.

## The features this example sets

### retry

```yaml
retry:
  numRetries: 3
  retryOn:
    httpStatusCodes: [503]
    triggers:
      - connect-failure
      - reset
      - retriable-status-codes      # enables retry on the httpStatusCodes
  perRetry:
    timeout: 1s
    backOff:
      baseInterval: 100ms
      maxInterval: 1s
```

- `triggers:` is the set of **conditions** to retry on (named
  shortcuts for what Envoy supports).
- `httpStatusCodes:` is the **list of specific 5xx codes** to retry.
  Including it requires `retriable-status-codes` in `triggers:`
  (the named trigger that says "consult the list").
- `perRetry.timeout` is per attempt; `timeout.http.requestTimeout`
  is per call (all attempts together). If perRetry × numRetries
  exceeds requestTimeout, the latter wins.

### timeout

```yaml
timeout:
  http:
    requestTimeout: 2s
    # connectionIdleTimeout: 1h
```

`requestTimeout` is what the client sees. `connectionIdleTimeout`
applies to keep-alive upstream connections.

### loadBalancer

```yaml
loadBalancer:
  type: LeastRequest             # default RoundRobin
  # consistentHash:
  #   type: Header
  #   header:
  #     name: x-user-id
```

`LeastRequest` chooses the backend with the fewest active requests
— good when request durations vary. `ConsistentHash` pins requests
to the same backend based on a header / cookie / sourceIP — needed
for session affinity.

### healthCheck.active

```yaml
healthCheck:
  active:
    type: HTTP
    timeout: 1s
    interval: 5s
    unhealthyThreshold: 3
    healthyThreshold: 2
    http:
      path: /
      expectedStatuses: [200]
```

Envoy sends a request to every endpoint every `interval`. After
`unhealthyThreshold` consecutive failures, the endpoint is removed
from the pool until `healthyThreshold` consecutive successes bring
it back.

### healthCheck.passive (outlier detection)

```yaml
healthCheck:
  passive:
    consecutive5XxErrors: 3
    interval: 10s
    baseEjectionTime: 30s
    maxEjectionPercent: 100
```

Eject an endpoint that returns N consecutive 5xx responses during
real traffic. Cheaper than active probing (no extra requests) —
catches things active probes might miss (e.g. a backend that
serves `/` fine but errors on real requests).

## How retry + timeout compose

```
Client                Envoy                                          Backend
------                -----                                          -------
GET /fail?code=503 -->
                      t=0.0s  attempt 1 -->                          503
                      t=0.0s  retry decision: retriable-status-code
                      t=0.1s  attempt 2 -->                          503
                      t=0.3s  attempt 3 -->                          503
                      t=0.6s  attempt 4 -->                          503
                      t=0.6s  numRetries=3 exhausted
                      <-- 503 to client (with x-envoy-attempt-count: 4)
                      
GET /slow?seconds=5 -->
                      attempt 1 starts...                              (sleeping)
                      t=2.0s  requestTimeout fires
                      attempt cancelled
                      <-- 504 Gateway Timeout
```

The `make verify` retry section dumps the Envoy access log so you
can count attempts. The timeout section measures wall-clock time.

## Where each field lands in /config_dump

Section 5 of `make verify` extracts the relevant slices:

```
cluster
├── lb_policy: LEAST_REQUEST                  ← loadBalancer.type
├── outlier_detection                          ← healthCheck.passive
│   ├── consecutive_5xx: 3
│   ├── base_ejection_time: 30s
│   └── max_ejection_percent: 100
├── health_checks[]                           ← healthCheck.active
│   ├── timeout: 1s, interval: 5s
│   └── http_health_check: { path: /, ... }
├── circuit_breakers                          ← (defaults; see commented-out CR)
└── connect_timeout                           ← timeout.tcp.connectTimeout

route_config.virtual_hosts[].routes[].route
├── timeout: 2s                               ← timeout.http.requestTimeout
└── retry_policy                              ← retry.*
    ├── retry_on: "retriable-status-codes,connect-failure,reset"
    ├── num_retries: 3
    ├── per_try_timeout: 1s
    ├── retriable_status_codes: [503]
    └── retry_back_off
```

## Common failure modes

| Symptom                                                              | Cause                                                                                                                |
|-----------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| `retryOn.httpStatusCodes` set but Envoy still doesn't retry           | Forgot `retriable-status-codes` in `triggers:`. The list is consulted only when that trigger is enabled.            |
| `requestTimeout: 2s` set but request runs longer                      | Per-retry timeout × numRetries = total. Wrap the math: `perRetry.timeout * (numRetries+1)` should be ≤ `requestTimeout`. |
| `BackendTrafficPolicy Conflicted=True`                                | Another BTP targets the same Service/section. Merge them.                                                            |
| Active HC always reports unhealthy                                    | `http.path` doesn't return `expectedStatuses` 200 (e.g. `/healthz` doesn't exist on this app — we use `/`).         |
| Outlier ejection never fires                                          | `consecutive5XxErrors` count is per-endpoint, reset on the first 2xx. Real traffic that mixes success/failure won't accumulate. |
| LeastRequest doesn't visibly differ from RoundRobin                   | With short, evenly-distributed requests, the two are statistically indistinguishable. Use long requests + `/slow`. |
| Retries hammer a dying backend                                        | Add `circuitBreaker.maxParallelRetries:` to cap concurrent retries cluster-wide.                                    |

## Exercises

1. **Limit retry storm.** Set `circuitBreaker.maxParallelRetries: 1`.
   Hit `/fail?code=503` from 10 parallel curl processes. Confirm
   that only one retries at a time and the rest get the upstream
   error immediately.

2. **Consistent-hash LB.** Switch to
   `loadBalancer.type: ConsistentHash` with
   `consistentHash.header.name: x-user-id`. Send 20 requests with
   `-H 'x-user-id: alice'`, then 20 with `-H 'x-user-id: bob'`.
   Confirm each user sticks to one replica (look at `from_` in
   the response).

3. **Outlier in practice.** Deploy a second helloworld replica
   with `env BREAK=true` (always returns 500). Watch
   `outlier_detection` eject it within a couple of seconds of
   real traffic. Then unset `BREAK` and watch the endpoint return
   to the pool after `baseEjectionTime`.

4. **Fault injection.** Add
   `faultInjection.delay: { fixedDelay: 5s, percentage: 50 }`. Hit
   the Gateway 10 times — half the requests should hang for 5s
   before returning. Map this to Phase 1 example 08's fault filter.

5. **Per-port BTP.** Split the BTP into TWO policies: one with
   short timeout / aggressive retries for a "fast" Service port,
   one with long timeout / no retries for a "slow" port. Use
   `sectionName:` to target each port separately.

## Cleanup

```bash
make down
```

## What's next

- [`13-securitypolicy-jwt`](../13-securitypolicy-jwt/) — JWT
  validation via `SecurityPolicy`. Mirrors Phase 1 example 12.
