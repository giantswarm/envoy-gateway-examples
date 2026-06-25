# 19 — gRPC and gRPC-Web

Two listeners on one Envoy:

- **:10001** — native HTTP/2 gRPC. Server-to-server clients (Go,
  Java, Python with grpcio) hit this. No translation, just HTTP/2
  in and HTTP/2 out.
- **:10000** — gRPC-Web. Browsers can't speak native gRPC because
  the JS fetch API can't produce HTTP/2 trailers. Envoy's
  `grpc_web` filter accepts the HTTP/1.1 framing browsers use
  (`Content-Type: application/grpc-web-text` etc.) and translates
  it to native gRPC before forwarding upstream.

Backend is [`moul/grpcbin`](https://github.com/moul/grpcbin) — the
same reference server used in Phase 2 ex 06.

## Run it

```bash
make up && make verify
make down
```

Needs `grpcurl` on your PATH (`brew install grpcurl`).

## When to use gRPC-Web

You're writing browser JS (or React Native, or any HTTP/1.1-only
runtime) and the team picked gRPC for the service contracts.
gRPC-Web is the bridge: keep the same `.proto` files, generate JS
client stubs with `protoc-gen-grpc-web`, point them at Envoy.

You'll always want CORS configured alongside (browser apps), so
this example pairs the two.

## Three filters, in this order

```yaml
http_filters:
  - cors          # short-circuits OPTIONS, stamps allow-origin headers
  - grpc_web      # translates HTTP/1.1 grpc-web framing -> HTTP/2 gRPC
  - router        # forwards to upstream cluster
```

If you swap `grpc_web` and `router`, the upstream sees HTTP/1.1
gRPC-Web framing and the call fails. If you put `cors` AFTER
`grpc_web`, preflight responses miss the allow-origin headers.

## HTTP/2 to the upstream

The upstream cluster MUST be HTTP/2, hence:

```yaml
typed_extension_protocol_options:
  envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
    "@type": .../HttpProtocolOptions
    explicit_http_config:
      http2_protocol_options: {}
```

Without that, Envoy speaks HTTP/1.1 upstream and grpcbin returns
"HTTP/2 over cleartext was not enabled" (or just hangs).

Phase 2 example 06's equivalent: setting `appProtocol:
kubernetes.io/h2c` on the K8s Service. Same concept, different
config surface.

## Phase 2 equivalent

[`02-envoy-gateway/06-grpcroute`](../../02-envoy-gateway/06-grpcroute/)
covers native gRPC via `GRPCRoute`. EG doesn't surface grpc-web
specifically — you'd combine an HTTPRoute (with the grpc_web
filter injected via `EnvoyPatchPolicy`, ex 18) for browser
traffic plus a GRPCRoute for server-to-server.

## Common pitfalls

- `codec_type: HTTP2` on the :10001 listener is required for native
  gRPC. Default is `AUTO` which expects HTTP/1.1 first.
- The cluster's `http2_protocol_options: {}` is REQUIRED; gRPC
  needs HTTP/2 end-to-end.
- `Content-Type: application/grpc-web` vs `application/grpc-web-text`
  — both exist. `-text` is base64-encoded (works with the JS fetch
  API), bare is binary (faster, but needs ArrayBuffer support).
- CORS `expose_headers: "grpc-status, grpc-message"` — without
  exposing these, the browser can't read the gRPC trailers, and
  errors look mysterious to the JS app.

## Exercises

1. Disable `cors` and try the preflight from a browser origin —
   confirm the call breaks. Re-enable, confirm it works.
2. Add a SECOND gRPC backend (e.g. another grpcbin replica). Route
   `hello.HelloService` to one and `grpcbin.GRPCBin` to the other
   via separate `route_config.routes[]` entries.
3. Drop the `http2_protocol_options: {}` on the cluster and observe
   the failure mode in `make logs`.
