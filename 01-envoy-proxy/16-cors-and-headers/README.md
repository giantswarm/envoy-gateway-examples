# 16 — CORS + header manipulation

Two related features:

1. **CORS** via `envoy.filters.http.cors`. Preflight OPTIONS
   short-circuit at the filter level; the backend never sees them.
   Allowed origins are matched exactly OR via regex (wildcard
   subdomains).
2. **Static header injection** at three scopes:
   - **vhost-level** `response_headers_to_add` — security headers
     applied to every response (`x-frame-options`, HSTS, etc.).
   - **vhost-level** `request_headers_to_add` — labels Envoy stamps
     on requests before they reach the backend.
   - **route-level** override — `/admin` adds `cache-control:
     no-store` on top of the vhost headers.

## Run it

```bash
make up && make verify
make down
```

## CORS filter shape

```yaml
http_filters:
  - name: envoy.filters.http.cors
    typed_config: { "@type": .../v3.Cors }
  - name: envoy.filters.http.router
    typed_config: { ... }
```

Per-vhost policy via `typed_per_filter_config`:

```yaml
virtual_hosts:
  - name: hello
    typed_per_filter_config:
      envoy.filters.http.cors:
        "@type": .../v3.CorsPolicy
        allow_origin_string_match:
          - exact: https://app.example.com
          - safe_regex: { regex: '^https://[a-z0-9-]+\.partners\.example\.com$' }
        allow_methods: "GET, POST, OPTIONS"
        allow_headers: "authorization, content-type"
        max_age: "3600"
        allow_credentials: true
```

The old inline `cors:` block on `virtual_host` is deprecated — use
`typed_per_filter_config` going forward.

## Phase 2 equivalent

`SecurityPolicy.cors` in [`02-envoy-gateway/15-...`](../../02-envoy-gateway/15-securitypolicy-basicauth-cors-ipallow/)
covers the same ground in CRD form.

## Header injection — three scopes

| Scope             | Applied to                                          |
|-------------------|------------------------------------------------------|
| `route_config`-level | Every request served on this route_config (all vhosts). |
| `virtual_host`-level | Every request matching this vhost.                      |
| `route`-level     | Just that route (used here for `/admin` no-cache).     |

Same pattern for `request_headers_to_add` / `response_headers_to_add`.

## Common pitfalls

- The CORS filter MUST be before the router — otherwise the OPTIONS
  preflight falls through to the route, gets a 404 from your backend,
  and breaks the browser flow.
- `allow_credentials: true` is mutually exclusive with `allow_origin: *`.
  Always list specific origins (or use regex).
- Security headers like `strict-transport-security` only have effect
  over HTTPS — they're harmless on HTTP but worthless until you add
  TLS (see ex 09).
- The browser DevTools Network tab shows OPTIONS preflights even when
  curl-from-CLI doesn't trigger them. Use the Network tab when
  debugging real apps.

## Exercises

1. Add `x-request-id` injection at vhost level so backends can
   correlate logs. Hint: Envoy auto-generates one if not present —
   you might not need to add anything.
2. Disable HSTS for one specific route (e.g. `/legacy`) by setting
   `response_headers_to_add` with `header: { value: "" }` doesn't
   work — Envoy doesn't have a "remove" override at route level for
   vhost-stamped headers; describe the workaround.
3. Add a Vary header to control caching.
