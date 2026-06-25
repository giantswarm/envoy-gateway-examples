# 18 — Distributed tracing via OTLP → Jaeger

Envoy exports trace spans over OTLP gRPC to a local Jaeger
all-in-one. Every request generates a span; we add custom tags
(`env: tutorial`, `x_user_id` from a request header) and view
them in Jaeger's UI.

## Run it

```bash
make up && make verify
open http://localhost:16686/search?service=envoy-tutorial-18
make down
```

The Jaeger UI lives at <http://localhost:16686>. Filter by service
`envoy-tutorial-18`.

## Three places tracing is configured

1. **Top-level `tracing.http`** in the bootstrap — names the
   provider and where to ship spans.

   ```yaml
   tracing:
     http:
       name: envoy.tracers.opentelemetry
       typed_config:
         "@type": .../OpenTelemetryConfig
         grpc_service:
           envoy_grpc: { cluster_name: otel_collector }
         service_name: envoy-tutorial-18
   ```

2. **Listener-level `tracing`** — per-listener sampling + tags.

   ```yaml
   tracing:
     random_sampling: { value: 100.0 }      # %
     custom_tags:
       - { tag: env, literal: { value: tutorial } }
       - { tag: x_user_id, request_header: { name: x-user-id, default_value: anonymous } }
   ```

3. **Cluster pointing at the OTLP backend** — must be HTTP/2,
   hence the `http2_protocol_options: {}` block. Without that,
   OTLP gRPC fails the handshake.

## Sampling

`random_sampling.value` is a percentage. `100.0` = trace
everything (tutorial). Real-world: `1.0` to `10.0` is normal at
high RPS — tracing is cheap but the backend storage isn't free.

## Phase 2 equivalent

[`02-envoy-gateway/21-observability`](../../02-envoy-gateway/21-observability/)
wires the same OTLP exporter via `EnvoyProxy.telemetry.tracing`,
plus access logs + Prometheus metrics in one CR.

## Common pitfalls

- Jaeger version pin — older Jaeger doesn't enable OTLP. We use
  `1.56` + `COLLECTOR_OTLP_ENABLED=true`.
- `http2_protocol_options: {}` is the magic incantation. Without
  it OTLP gRPC says "received non-gRPC frame", spans never arrive.
- Verifying spans went through: easier via the Jaeger HTTP API
  (`/api/services`, `/api/traces`) than the UI — see `verify.sh`.
- If `make verify` reports 0 traces, wait 3-5 seconds and re-run.
  Jaeger's batch processor flushes on a timer.

## Exercises

1. Lower sampling to 10%. Send 100 requests, confirm Jaeger has
   ~10 traces (use the API: `?limit=200&service=envoy-tutorial-18`).
2. Add a `route_header` custom tag that captures `:method`. Verify
   in the UI that the tag shows up on individual spans.
3. Trigger a 503 from the backend (use Phase 1 ex 06's `/fail`
   helper) and observe in the UI that the span is tagged `error=true`.
