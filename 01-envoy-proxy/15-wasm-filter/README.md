# 15 — Wasm filter

The most flexible HTTP filter you have: a chunk of compiled-to-Wasm code
that Envoy loads into a V8 sandbox and runs on every request. You can
write it in **Rust**, **Go (via TinyGo)**, **AssemblyScript**, or **C++**;
the contract on both sides is the [proxy-wasm ABI](https://github.com/proxy-wasm/spec).
This example ships a tiny Rust filter in `filter/`, built inside a
throwaway Rust container so you don't need a host toolchain.

The filter:

- Adds `x-wasm-filter: hello-from-wasm` to every response.
- Returns `403` directly (no upstream hop) if the request carries
  `x-wasm-block`.
- Logs an info breadcrumb when the request has `x-wasm-greet: <anything>`.

By the end of this example you should be able to answer:

- How does a Wasm filter plug into the HCM chain?
- What's `vm_config.runtime` and what runtimes are available?
- What's the request lifecycle inside the filter (`on_http_request_headers`,
  `on_http_response_headers`, `send_http_response`, …)?
- When should I reach for Wasm vs Lua vs ext-authz vs a native filter?

## Prerequisites

- Done [`01`](../01-helloworld-static/) through [`13`](../13-ext-authz/).
  (Example 14 is skipped — Lua-based equivalent of the same idea.)
- Docker, `docker compose`, `curl`. **No Rust toolchain on the host** —
  the build runs in a container.

## Run it

```bash
make up           # builds the .wasm in Docker the first time (~2min)
make verify       # 4 scenarios: regular response, block path, log breadcrumb, stats
make logs         # see the wasm filter's info logs alongside Envoy's
make down

# After editing filter/src/lib.rs:
make build-wasm   # rebuilds incrementally (fast)
make reload       # restart Envoy to pick up the new .wasm
```

The first build downloads the `rust:1.78` image (~1.5 GB) and compiles
the SDK; expect 1–2 minutes. Subsequent incremental builds are
sub-second because Cargo caches in the bind-mounted `filter/target/`.

## Where it sits

```yaml
http_filters:
  - name: envoy.filters.http.wasm
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
      config:
        name: hello_wasm
        vm_config:
          runtime: envoy.wasm.runtime.v8
          code:
            local:
              filename: /etc/envoy/wasm/filter.wasm
  - name: envoy.filters.http.router
    ...
```

Same HCM chain you've seen in every example. The Wasm filter is a
regular HTTP filter — it can sit anywhere in the chain, and its
behavior composes with the other filters around it (e.g. you can run
JWT auth, then Wasm mutation, then router).

## Runtimes

`vm_config.runtime` picks the Wasm engine Envoy loads the bytecode
into. Stock `envoyproxy/envoy:v1.34.1` ships with:

| Runtime                          | What it is                                        |
|----------------------------------|---------------------------------------------------|
| `envoy.wasm.runtime.v8`          | V8 (Google's JS engine running Wasm). Default.   |
| `envoy.wasm.runtime.null`        | "No sandbox" — runs the filter as a native       |
|                                  | extension. Debug only.                            |

Other community builds may include `wamr`, `wasmtime`, `wasmedge`. They
swap with no source changes; the proxy-wasm ABI is portable.

## The filter source

```rust
proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Info);
    proxy_wasm::set_http_context(|_, _| -> Box<dyn HttpContext> {
        Box::new(HelloFilter)
    });
}}

struct HelloFilter;

impl Context for HelloFilter {}

impl HttpContext for HelloFilter {
    fn on_http_request_headers(&mut self, _: usize, _: bool) -> Action {
        if self.get_http_request_header("x-wasm-block").is_some() {
            self.send_http_response(
                403,
                vec![("content-type", "text/plain")],
                Some(b"blocked by wasm filter\n"),
            );
            return Action::Pause;
        }
        Action::Continue
    }

    fn on_http_response_headers(&mut self, _: usize, _: bool) -> Action {
        self.add_http_response_header("x-wasm-filter", "hello-from-wasm");
        Action::Continue
    }
}
```

The pieces:

- **`proxy_wasm::main!`** — entry point macro. Runs once when Envoy
  loads the .wasm; registers the log level and the per-request context
  factory.
- **`HttpContext`** — one instance per HTTP request. Methods are
  callbacks: `on_http_request_headers`, `on_http_request_body`,
  `on_http_response_headers`, `on_http_response_body`,
  `on_http_call_response`, `on_log`.
- **`Action::Continue`** — pass control to the next filter.
- **`Action::Pause`** — buffer further data and wait. Resume with
  `resume_http_request()` / `resume_http_response()`. Used when calling
  out to another service before deciding (see `dispatch_http_call`).
- **`send_http_response`** — short-circuit. Envoy returns the response
  immediately, doesn't invoke the upstream, and doesn't run further
  filters. Pair with `Action::Pause` so Envoy doesn't double-send.

## Build pipeline

```
filter/src/lib.rs
   │
   │ cargo build --target wasm32-wasip1 --release
   ▼
filter/target/wasm32-wasip1/release/hello_wasm.wasm
   │
   │ docker-compose bind-mount
   ▼
/etc/envoy/wasm/filter.wasm   (inside the envoy container)
   │
   │ envoy.filters.http.wasm.vm_config.code.local.filename
   ▼
Loaded into the V8 VM
```

The Makefile target `$(WASM)` has `filter/src/lib.rs` + `Cargo.toml` as
prereqs, so `make build-wasm` rebuilds on source change. The compiled
.wasm is ~50 KB for this filter; production filters run 50 KB to a few
MB depending on what crates you pull in.

## Loading a .wasm — three sources

```yaml
code:
  local:
    filename: /etc/envoy/wasm/filter.wasm   # this example
# or
code:
  local:
    inline_bytes: "<base64 of the .wasm>"   # embed in the config
# or
code:
  remote:
    http_uri:
      uri: "https://example.com/filter.wasm"
      cluster: filter_repo_cluster
      timeout: 30s
    sha256: "abc123..."                     # required, integrity check
```

For Phase 2 (Envoy Gateway) you'll see this surface as the
**EnvoyExtensionPolicy** CR — but underneath it produces exactly the
same `Wasm` proto.

## When to reach for Wasm

| Mechanism            | When to use                                                |
|----------------------|------------------------------------------------------------|
| **Wasm**             | Stateful per-request logic, complex transforms, language flexibility, fully sandboxed. |
| **Lua filter** (ex 14) | Quick one-off mutation, no compile step, less safety.    |
| **ext-authz** (ex 13)| Decision belongs to a service (policy engine, IAM).        |
| **Native filter**    | Hot path, microsecond budget, willing to maintain a fork. |
| **Header manipulation** | `request_headers_to_add` / `to_remove` on the route.    |

Rough cost model: Wasm filter callback overhead is around 1–10 µs in
V8; native filters are tens of nanoseconds; ext-authz adds a network
round-trip (typically 0.5–5 ms). Pick by the cost you can afford.

## What the verify script demonstrates

| Step | Request                                | Expected                                  |
|------|----------------------------------------|-------------------------------------------|
| 1    | `GET /anything`                        | 200; response has `x-wasm-filter: hello-from-wasm` |
| 2    | `GET /anything` + `x-wasm-block: yes`  | 403, body "blocked by wasm filter", no backend hop |
| 3    | `GET /anything` + `x-wasm-greet: hi`   | 200; wasm log line appears in Envoy stdout |
| 4    | `/stats?filter=wasm`                   | Per-VM counters: `wasm.hello_wasm.*`, `wasm.envoy.wasm.runtime.v8.*` |

## Common failure modes

| Symptom                                                | Likely cause                                              |
|--------------------------------------------------------|------------------------------------------------------------|
| `make up` errors with "no such file or directory" on `filter.wasm` | `make build-wasm` never ran or produced nothing. Inspect `make build-wasm` output. |
| Envoy starts but logs `unable to load .wasm`           | Path mismatch between `docker-compose.yml` volume mount and `envoy.yaml` `filename:`. |
| Filter loaded but no header added                      | Crash inside the Wasm module — V8 logs to Envoy stderr. Add `set_log_level(LogLevel::Trace)` and reload. |
| Build is glacially slow every time                     | `filter/target/` mount is missing; Cargo can't cache. |
| Build fails on M1/M2 Macs with "wasm32-wasip1 not found" | Older `rust:1.7x` images may need `wasm32-wasi` instead. Update Cargo.toml + Makefile target. |

## Exercises

1. **Add config from `envoy.yaml`.** Set
   `config.configuration.value: "{\"header\":\"x-from-config\"}"` and
   read it in the filter via `RootContext::on_configure`. Override
   the hard-coded header name with what comes from config.

2. **Call out to an upstream from the filter.** Use
   `dispatch_http_call` to invoke a side service before allowing the
   request. (Real-world example: ask a cache or a feature-flag service
   before passing through.)

3. **`remote_jwks`-style remote loading.** Move the .wasm to a tiny
   nginx container, expose it as a URL, switch `code` to the `remote`
   variant with `sha256`. Confirm Envoy fetches and caches it.

4. **TinyGo version.** Reimplement `lib.rs` as a Go file built with
   TinyGo (`tinygo build -o filter.wasm -target wasi`). Same behavior,
   different toolchain. Wasm is portable across SDKs.

5. **Compare to ext-authz.** Move the `x-wasm-block` logic to the
   ext-authz example. Which one's a better fit for "block based on
   shape of the request"? When does Wasm win?

## Cleanup

```bash
make down
make clean-wasm    # remove filter/target/ to reclaim disk
```

## What's next

- **`16-cors-and-headers`** — back to built-in filters: CORS preflight
  handling and request/response header manipulation patterns.
