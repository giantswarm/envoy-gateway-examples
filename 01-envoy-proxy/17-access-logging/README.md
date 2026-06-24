# 17 — Access logging

We've been looking at Envoy's stock access log line since example 01.
Now we take control: three sinks side by side, two formats (text and
JSON), and a filter that keeps the error log free of noise.

By the end of this example you should be able to answer:

- Where does the access log config live and what's its shape?
- What's the difference between `text_format_source` and `json_format`?
- What format operators (`%REQ(...)%`, `%DURATION%`, `%RESPONSE_FLAGS%`,
  ...) exist?
- How do `filter:` blocks let one sink ignore noise the others keep?
- How would I wire Envoy's logs to Loki / Elasticsearch / Datadog?

## Prerequisites

- Done [`01`](../01-helloworld-static/) through [`15`](../15-wasm-filter/).
  (Examples 14 and 16 are deferred.)
- Docker, `docker compose`, `curl`, `jq`.

## Run it

```bash
make up
make verify        # generates traffic, inspects each sink
make traffic       # pump more traffic on demand
make tail-json     # follow the JSON sink in another terminal
make tail-errors   # follow the errors-only sink
make down
```

## Anatomy

```yaml
access_log:           # a LIST of sinks; every request runs them all
  - name: ...         # the sink type (stdout / file / OTLP gRPC / …)
    typed_config:
      "@type": ...
      path: /var/log/envoy/access.json   # file sink only
      log_format:
        text_format_source: { inline_string: "..." }     # OR
        json_format: { key: "%OPERATOR%", ... }
    filter:           # optional — drop requests that fail the filter
      status_code_filter: { ... }
```

Each entry of `access_log:` is independent. You can mix:

- A noisy human-friendly text format on stdout.
- A structured JSON file for the log shipper.
- An errors-only file the on-call pager scrapes.
- An OTLP-gRPC sink shipping to a backend like Datadog.

## Sink types

| Sink                                                  | What for                                 |
|-------------------------------------------------------|------------------------------------------|
| `envoy.access_loggers.stdout` / `.stderr` (`StreamAccessLog`) | Container logs. Easiest in Kubernetes.   |
| `envoy.access_loggers.file` (`FileAccessLog`)         | Write to a file path. Pair with sidecars / DaemonSet log shippers. |
| `envoy.access_loggers.open_telemetry` (`OpenTelemetryAccessLogConfig`) | OTLP gRPC. Vendor-neutral pipeline. |
| `envoy.access_loggers.tcp_grpc` (`TcpGrpcAccessLogConfig`) / `.http_grpc` | gRPC-based access log services (Envoy's own ALS proto). |
| `envoy.access_loggers.wasm`                            | Custom Wasm-based logging. Rare.        |

## Format strings

There are two source kinds:

### Text format

```yaml
text_format_source:
  inline_string: "[%START_TIME%] \"%REQ(:METHOD)% %REQ(:PATH)% %PROTOCOL%\" %RESPONSE_CODE%\n"
```

A printf-style template. Operators expand at log time. **Must end with
`\n`** — Envoy doesn't add one.

### JSON format

```yaml
json_format:
  start_time: "%START_TIME%"
  method:     "%REQ(:METHOD)%"
  status:     "%RESPONSE_CODE%"
  static_tag: "envoy-example-17"
```

One JSON object per line. Keys are static strings; values can be format
operators or static strings. Numeric operators come out as JSON numbers
(`%RESPONSE_CODE%` → `200`, not `"200"`).

### The operator zoo

Operators you'll use most:

| Operator                          | What it expands to                                       |
|-----------------------------------|----------------------------------------------------------|
| `%START_TIME%`                    | ISO-8601 timestamp; `%START_TIME(%H:%M:%S)%` for strftime |
| `%PROTOCOL%`                      | `HTTP/1.1` / `HTTP/2` / `HTTP/3`                         |
| `%REQ(name)%` / `%RESP(name)%` / `%TRAILER(name)%` | Header lookups; `name` can be `:method`, `:path`, `:authority` |
| `%RESPONSE_CODE%`                 | HTTP status                                              |
| `%RESPONSE_FLAGS%`                | Two-letter codes (`UH`, `NR`, `UO`, `UT`, …)             |
| `%RESPONSE_CODE_DETAILS%`         | Why Envoy returned this code, in words                   |
| `%DURATION%`                      | Total time in ms                                         |
| `%REQUEST_DURATION%` / `%RESPONSE_DURATION%` | Phase durations                                |
| `%BYTES_RECEIVED%` / `%BYTES_SENT%` | Body sizes                                            |
| `%UPSTREAM_HOST%` / `%UPSTREAM_CLUSTER%` | What we routed to                                |
| `%REQUESTED_SERVER_NAME%`         | The SNI client sent (example 09)                         |
| `%ROUTE_NAME%` / `%VIRTUAL_HOST_NAME%` | The route table location that matched               |
| `%CONNECTION_ID%` / `%STREAM_ID%` | Identifiers for stitching with other logs                |
| `%DYNAMIC_METADATA(filter.key)%`  | Metadata set by an earlier filter (e.g. ext_authz)       |
| `%FILTER_STATE(name)%`            | Per-filter state                                          |
| `%CEL(<expr>)%`                   | [CEL](https://github.com/google/cel-spec) expression     |
| `%HOSTNAME%`                      | Pod / container hostname                                  |

Full list:
[Envoy command operators docs](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage.html#command-operators).

## Filters

```yaml
filter:
  status_code_filter:
    comparison:
      op: GE
      value:
        default_value: 500
        runtime_key: access_log.errors.min_status
```

This sink only logs requests with status ≥ 500. Filters available:

| Filter                       | Use case                                                |
|------------------------------|---------------------------------------------------------|
| `status_code_filter`         | Status threshold (errors-only logs)                     |
| `duration_filter`            | Only log requests slower than N ms                      |
| `not_health_check_filter`    | Drop `/healthz`-style probes                            |
| `response_flag_filter`       | Only log certain `RESPONSE_FLAGS` (e.g. `UH`, `UF`)     |
| `traceable_filter`           | Only when the request was sampled for tracing           |
| `runtime_filter`             | Sample N% of requests                                   |
| `header_filter`              | Match a request header value                            |
| `grpc_status_filter`         | gRPC status comparison                                   |
| `and_filter` / `or_filter`   | Compose multiple filters                                 |
| `extension_filter`           | Custom filter via an extension                          |

`default_value: 500` + `runtime_key: access_log.errors.min_status`
means **you can change the threshold without a reload** —
`POST /runtime_modify?access_log.errors.min_status=400`. Verify step 5
demonstrates this.

## Per-route override

Want a noisier log on `/admin` and a quieter one elsewhere? Attach
`access_log:` on the **route's** `typed_per_filter_config` for
`envoy.access_loggers.file` (or whichever sink). Less common than HCM-
level config; the typical pattern is HCM logs + filters.

## What the verify script demonstrates

| Step | Action                                              | Outcome                                            |
|------|-----------------------------------------------------|----------------------------------------------------|
| 1    | Send 5×200, 2×503, 1×slow                            | All three sinks observe                            |
| 2    | `docker compose logs envoy --tail 8`                 | Text format on stdout                              |
| 3    | `cat logs/access.json \| jq`                        | One JSON object per line, every request            |
| 4    | `cat logs/errors.log`                                | Only the 2 × 503 lines (filter at work)           |
| 5    | `POST /runtime_modify?...=400` then fire a 401      | 401 also appears in `errors.log`. Reset to 500.    |

## Production tips

- **Volume.** Access logs are the single noisiest signal Envoy emits.
  At sustained high RPS a JSON sink can rival the rest of the proxy in
  CPU. For Phase-2 production proxies, prefer OTLP/gRPC with batching
  to a sidecar Vector / Fluent Bit, not file logging.
- **Sampling.** Use `runtime_filter` to drop 9 of 10 successful
  requests but keep every error. Cheap by design.
- **Per-cluster vs per-listener.** Access logs are per-HCM. If you
  have multiple listeners and want cluster-aware logging, add
  `%UPSTREAM_CLUSTER%`.
- **Avoid logging the body.** Body access (`%RESP_BODY%` via
  `BufferingAccessLog` style) can blow up memory under load. Use
  body inspection in a filter (ext_authz / Wasm) and emit a fingerprint
  to the log instead.
- **Sensitive headers.** `%REQ(Authorization)%` will leak bearer
  tokens. Either skip those headers from format strings, or strip them
  upstream with `request_headers_to_remove`.
- **Cardinality.** JSON sinks shipped to time-series log stores explode
  in cost if you include unique-per-request fields *and* tag them.
  Keep tags (low cardinality) separate from fields (high cardinality).

## Exercises

1. **Sample only the slow ones.** Add a fourth sink `slow.log` with
   `duration_filter { comparison: { op: GE, value: { default_value: 500 } } }`
   — only requests taking longer than 500 ms get logged.

2. **Drop the healthchecks.** Add `not_health_check_filter: {}` (which
   reads the request header `x-envoy-healthcheck-cluster` for example
   `cluster.upstream` style probes) to the stdout sink. Send some
   normal requests + some with `-H "x-envoy-internal: true"` — observe
   the difference.

3. **OTLP-gRPC sink.** Add an OpenTelemetry collector container and a
   sink:

   ```yaml
   - name: envoy.access_loggers.open_telemetry
     typed_config:
       "@type": type.googleapis.com/envoy.extensions.access_loggers.open_telemetry.v3.OpenTelemetryAccessLogConfig
       common_config:
         log_name: envoy_access
         grpc_service:
           envoy_grpc: { cluster_name: otel_collector }
         transport_api_version: V3
       body: { string_value: "%REQ(:METHOD)% %REQ(:PATH)% %RESPONSE_CODE%" }
       attributes:
         values:
           - { key: status, value: { string_value: "%RESPONSE_CODE%" } }
   ```

   Requires an `otel_collector` cluster + the collector container; see
   example 18 (tracing) for an OTLP collector you can reuse.

4. **CEL expressions.** Add `%CEL(request.headers['x-tenant'] || 'unknown')%`
   to your JSON format. CEL lets you compute log fields instead of just
   reading them. Useful for derived tags.

5. **Per-vhost overrides.** Configure two virtual hosts (e.g.
   `api.local` from example 03) each with its own `access_log:` block.
   Confirm only the matching virtual host's logs are emitted for each
   request.

## Cleanup

```bash
make down
make clean-logs    # wipe logs/access.json + logs/errors.log
```

## What's next

- **`18-tracing-otlp`** — distributed tracing via OTLP to a local
  Jaeger. The other half of "observability".
