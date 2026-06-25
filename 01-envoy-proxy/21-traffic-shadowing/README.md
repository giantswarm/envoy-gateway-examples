# 21 — Traffic shadowing (request mirroring)

`request_mirror_policies` on a route lets you **tee** matching
requests to a second cluster, fire-and-forget:

- The **client** gets the response from the PRIMARY only.
- The **mirror cluster** receives the same request asynchronously.
- The mirror's response is **discarded**.
- The mirror's errors NEVER affect the client.

The real use case: deploy v2 of a service alongside v1, route
production traffic at v1, mirror to v2, compare logs / metrics /
shadow database writes, ship v2 when you trust it.

## Run it

```bash
make up && make verify
make logs-shadow         # in another terminal — watch shadow's traffic
make down
```

## The shape

```yaml
routes:
  - match: { prefix: "/" }
    route:
      cluster: primary
      request_mirror_policies:
        - cluster: shadow
          runtime_fraction:
            default_value: { numerator: 100, denominator: HUNDRED }
          trace_sampled: false
```

Multiple `request_mirror_policies[]` are allowed — fan out to N
shadow clusters at independent sampling rates.

### `runtime_fraction`

The mirror percentage. Hundred/HUNDRED = 100%. Pick a fraction to
canary just a slice:

```yaml
runtime_fraction:
  default_value: { numerator: 10, denominator: HUNDRED }   # 10%
```

It also accepts a `runtime_key:` so you can flip the percentage at
runtime via Envoy's `/runtime_modify` admin endpoint without a
config reload.

### Shadow host suffix

Envoy by default appends `-shadow` to the `:authority` (Host
header) on mirrored requests, so the upstream can tell: "this is a
shadow call, don't double-charge the customer". Disable with:

```yaml
- cluster: shadow
  disable_shadow_host_suffix_append: true
```

## Phase 2 equivalent

[`02-envoy-gateway/03-httproute-matching-and-filters`](../../02-envoy-gateway/03-httproute-matching-and-filters/)
demonstrates `RequestMirror` as an HTTPRoute filter — same idea,
CRD shape. The Gateway API filter is more limited (no sampling
fraction, no runtime override) — for those, fall back to
`EnvoyPatchPolicy` (Phase 2 ex 18).

## Common pitfalls

- **Side-effecting endpoints (POST /charge)** — shadowing fires
  the mutation TWICE. Use the `-shadow` host suffix at the
  upstream to skip side effects in shadow mode. Don't shadow if
  your upstream can't tell.
- **Latency budget** — the mirror runs in parallel, but Envoy
  still tracks its connection. If the mirror is slow, Envoy's
  connection pool can fill up; tune `circuit_breakers.max_connections`
  on the shadow cluster.
- **Stats prefix** — mirror traffic shows up under
  `envoy.cluster.<shadow-name>.upstream_rq_*`. Use that to monitor
  shadow health independently of primary.
- **Sampling vs comparison** — at low sample rates, randomized
  selection skews comparisons. Use a deterministic hash of a
  request property (header, session ID) if you need reproducible
  shadow sets.

## Exercises

1. Drop `runtime_fraction` to 10/HUNDRED. Send 100 requests and
   confirm shadow received ~10. Tune the seed.
2. Add a SECOND shadow cluster (`shadow_v3`). Confirm Envoy sends
   to both independently.
3. Run shadow on a slow backend (`/slow?seconds=5`). Use
   `circuit_breakers` on the shadow cluster to keep slow shadow
   from starving primary's connection pool.
4. Use `disable_shadow_host_suffix_append: true` and confirm the
   shadow upstream sees the original :authority. Useful when your
   upstream rejects unknown hostnames.
