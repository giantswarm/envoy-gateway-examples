# 14 — Lua filter

Run a small Lua script per request/response via
`envoy.filters.http.lua`. Use when you need a transformation Envoy
doesn't have natively but don't want the build complexity of Wasm
(example 15).

What this example shows:

- `envoy_on_request` injects `x-lua-greeting` based on an inbound
  header.
- `envoy_on_response` stamps `x-served-by-lua` on the way back.
- `handle:logInfo(...)` writes to Envoy's stdout.

## Run it

```bash
make up && make verify
make logs            # see lua: lines in envoy stdout
make down
```

## When NOT to use Lua

- Hot path with high CPU cost — Lua is interpreted; Wasm is faster
  for non-trivial work.
- Logic you'd want to unit-test — Wasm modules are easier to test
  independently.
- Anything sensitive — Lua runs in-process; bugs/loops can DoS
  Envoy. Wasm sandboxes more strictly.

The flip side: a 5-line Lua snippet beats a Rust toolchain every
time for the simple cases.

## Common pitfalls

- Header names in `:headers():get("X")` are case-insensitive but
  always returned LOWERCASE. Use lowercase in your script.
- `envoy_on_response` runs even if the backend errored — don't
  assume a 2xx.
- Per-route override via `typed_per_filter_config` is the way to
  attach DIFFERENT Lua per route; the inline `default_source_code`
  here applies to every route on this listener.

## Exercises

1. Read the request body in `envoy_on_request` and short-circuit
   with a 400 if it doesn't parse as JSON. Hint:
   `handle:body():getBytes(0, handle:body():length())`.
2. Compute a hash of `x-user-id` and add it as `x-tenant-hash`.
3. Per-route Lua via `typed_per_filter_config` — one route gets
   the greeting, the other doesn't.
