# Phase 1 — Envoy proxy standalone

Envoy in Docker, no Kubernetes, no Envoy Gateway. The goal is a solid mental
model of Envoy's config tree (listener → filter chain → HCM → route →
cluster → endpoint), so that when Phase 2 layers Envoy Gateway on top you
can read the generated Envoy config and know exactly what you're looking at.

Every example is self-contained: its own `Makefile`, its own
`docker-compose.yml`, its own annotated `envoy.yaml`. Run any of them with:

```bash
cd NN-name
make up
make verify
make down
```

**Switching examples is one command.** Every example uses the same host
ports (`:10000` data plane, `:9901` admin). `make up` first runs
[`scripts/free-ports`](../scripts/free-ports) to cleanly stop any other
example in this repo that's holding those ports, so you can `make up` in a
new directory without `make down`ing the previous one. Containers from
unrelated projects are left alone.

## Examples

Build order — later examples reference concepts from earlier ones.

| #  | Example                                              | Focus |
|----|------------------------------------------------------|-------|
| 01 | [`01-helloworld-static`](./01-helloworld-static/)    | The reference shape. One listener / route / cluster. Full config tour. |
| 02 | [`02-config-anatomy`](./02-config-anatomy/)          | Admin endpoints: `/config_dump`, `/clusters`, `/listeners`, `/stats`, `/runtime`, `/logging`. |
| 03 | [`03-routing-basics`](./03-routing-basics/)          | Virtual hosts, match types (`prefix` / `path` / `safe_regex` / `path_separated_prefix`), header + query gates, redirects, `direct_response`, rewrites, ordering. |
| 04 | [`04-load-balancing`](./04-load-balancing/)          | `ROUND_ROBIN`, `LEAST_REQUEST`, `RING_HASH` with `hash_policy`. Three backends, three clusters. |
| 05 | [`05-health-checks`](./05-health-checks/)            | Active health checks + outlier detection (passive). One bad backend + a kill/heal cycle on a healthy one. Includes a panic-mode exercise. |
| 06 | [`06-timeouts-retries`](./06-timeouts-retries/)      | Per-route `timeout` vs `per_try_timeout`, `retry_on`, `num_retries`, `previous_hosts` predicate, exponential `retry_back_off`. |
| 07 | [`07-circuit-breakers`](./07-circuit-breakers/)      | Per-cluster `max_connections` / `max_pending_requests` / `max_requests` / `max_retries`, `track_remaining` gauges, priorities, 15-concurrent burst demo. |
| 08 | [`08-fault-injection`](./08-fault-injection/)        | HTTP fault filter — fixed/probabilistic/header-driven delay + abort, `typed_per_filter_config` opt-in, runtime kill switch. |
| 09 | [`09-tls-termination`](./09-tls-termination/)        | Downstream TLS, per-SNI filter chains, `tls_inspector`, self-generated CA + leaf certs, `openssl s_client` cert inspection. Passthrough + mTLS as exercises. |
| 10 | [`10-rate-limiting-local`](./10-rate-limiting-local/) | `local_ratelimit` filter — token bucket per worker, `filter_enabled` vs `filter_enforced`, custom over-limit response, `x-ratelimit-*` headers, descriptors. |
| 11 | [`11-rate-limiting-global`](./11-rate-limiting-global/) | `envoy.filters.http.ratelimit` + envoyproxy/ratelimit + Redis. Descriptors, actions, wildcards, failure_mode_deny, gRPC cluster setup. |
| 12 | [`12-jwt-authn`](./12-jwt-authn/)                    | `jwt_authn` filter — providers, rules, `requires_any/_all/_missing`, local vs remote JWKS, claim forwarding via `forward_payload_header` and `claim_to_headers`. Self-minted RSA keys + bash token signer. |
| 13 | [`13-ext-authz`](./13-ext-authz/)                    | `ext_authz` filter (HTTP variant) talking to a small Flask authz service. Header allow-lists, per-route disable, `failure_mode_allow`. |
| 14 | `14-lua-filter` *(deferred)*                         | Per-request mutation via Lua — covered conceptually inside example 15. |
| 15 | [`15-wasm-filter`](./15-wasm-filter/)                | Rust proxy-wasm filter built inside Docker (no host Rust toolchain). Adds response headers, short-circuits with 403, logs breadcrumbs. |
| 16 | `16-cors-and-headers` *(planned)*                    | CORS + header manipulation. |
| 17 | [`17-access-logging`](./17-access-logging/)          | Three sinks side-by-side (stdout text, file JSON, errors-only file), format operators, `status_code_filter`, runtime-tunable threshold. |
| 18 | `18-tracing-otlp` *(planned)*                        | OTLP → Jaeger. |
| 19 | `19-grpc-and-grpc-web` *(planned)*                   | gRPC routing + grpc-web bridge. |
| 20 | `20-websocket` *(planned)*                           | Upgrade handling. |
| 21 | `21-traffic-shadowing` *(planned)*                   | Mirror to a second backend. |
