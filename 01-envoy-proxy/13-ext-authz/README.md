# 13 — External authorization

Authentication (example 12) decides **who** the caller is. **Authorization**
decides **what they're allowed to do** — and that policy almost always
needs to live somewhere richer than Envoy YAML. The `ext_authz` filter
calls out to an external service on every request and lets that service
return ALLOW or DENY.

This example wires Envoy to a tiny Flask service (`authz/`) that
implements a toy policy:

| Path        | Required                                  |
|-------------|-------------------------------------------|
| `/public`   | nothing — ext-authz is disabled per-route |
| `/protected/*` | any `x-user-id` header                  |
| `/admin/*`  | `x-user-role: admin`                      |

In production this is where you'd run **Open Policy Agent (OPA)**,
**Authorino**, **OAuth2-proxy**, or a homegrown service that talks to
your IAM system.

By the end of this example you should be able to answer:

- What does the ext_authz HTTP contract look like?
- What's `allowed_headers` vs `allowed_upstream_headers` vs `allowed_client_headers`?
- How do I disable ext-authz on a specific route?
- What should `failure_mode_allow` be set to?
- When do I want the gRPC variant instead of HTTP?

## Prerequisites

- Done [`01`](../01-helloworld-static/) through [`12`](../12-jwt-authn/).
- Docker, `docker compose`, `curl`, `jq`.

## Run it

```bash
make up
make verify        # 8 scenarios incl. failure-mode-allow demo
make authz-logs    # see the authz service's per-request decisions
make down
```

## The HTTP contract

Envoy translates the *original* request into an HTTP call to the authz
service:

```
HTTP/1.1 GET /protected/foo
:authority: helloworld
:method: GET
:path: /protected/foo
x-user-id: alice
x-request-id: <uuid>
... etc
```

The authz service must respond:

- **`200`** → allow. Any response headers in `allowed_upstream_headers`
  are *added to the upstream request* (the backend sees them).
- **non-2xx** → deny. Envoy returns the *same status code* to the
  client, plus any response headers in `allowed_client_headers`.

A few things that confuse newcomers:

- The **path** the authz service sees defaults to the *original* path.
  Use `path_prefix:` to add a prefix (so `/protected/foo` becomes
  `/check/protected/foo`).
- The **body** is NOT forwarded by default. Set
  `with_request_body { max_request_bytes: N }` to include it.
- The **upstream request method** is preserved; the authz service sees
  the original `GET`/`POST`/etc.
- Headers are filtered by `allowed_headers` — anything not on the
  allow-list is stripped before the authz hop. Default: only `:method`,
  `:path`, `:authority`, `x-request-id`.

## Header allow-lists

```yaml
authorization_request:
  allowed_headers:
    patterns:
      - exact: x-user-id
      - exact: x-user-role
authorization_response:
  allowed_upstream_headers:
    patterns:
      - exact: x-authz-decision
  allowed_client_headers:
    patterns:
      - exact: x-authz-reason
```

Three independent allow-lists. Picture them by direction:

| List                       | Direction                     | Used for                                    |
|----------------------------|-------------------------------|---------------------------------------------|
| `allowed_headers`          | client → authz                | Tell authz what the client sent (e.g. JWT) |
| `allowed_upstream_headers` | authz → backend (on allow)    | Inject context (`x-authz-decision`, user ID, ...) |
| `allowed_client_headers`   | authz → client (on deny)      | Tell the client why                         |

**Defaults are restrictive** — if you forget to add a header to
`allowed_headers`, the authz service won't see it and your policy will
mysteriously deny. That's the most common debugging trail for this
filter.

## Per-route disable

```yaml
- match: { path: "/public" }
  route: { cluster: hello_cluster, ... }
  typed_per_filter_config:
    envoy.filters.http.ext_authz:
      "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthzPerRoute
      disabled: true
```

Pattern: filter applies globally, opt-out per route for healthchecks
and public docs. The alternative — `check_settings.disabled: true` —
is older syntax; `ExtAuthzPerRoute.disabled` is current.

## `failure_mode_allow`

What happens when the authz service is down, slow, or errors?

```yaml
failure_mode_allow: false   # deny (this example)
failure_mode_allow: true    # allow
```

- **`false` (deny)** is the conservative default. If you can't ask the
  policy, refuse traffic.
- **`true` (allow)** keeps you serving when authz blips. Use for
  low-risk authz where availability > correctness (e.g. metering,
  optional features).

Verify step 8 in `verify.sh` stops the authz container and confirms
`/protected` returns 403 with `failure_mode_allow: false`. Flip the
flag and re-test to see the opposite behavior.

## HTTP vs gRPC ext-authz

We're using HTTP here for simplicity. The gRPC variant is the
canonical interface (`envoy.service.auth.v3.Authorization`) and gives
you:

- **Streaming-friendlier** — one connection, many requests; sub-ms
  latency in steady state.
- **Native body forwarding** — `attributes.request.http.body`.
- **Richer response** — set arbitrary headers to add/remove, return
  reason codes, override the response body.
- **First-class integration** with OPA (`opa run --server` with
  `--envoy-plugin`), Authorino, Keycloak Gatekeeper, and Istio's
  authz.

The trade-off is build complexity: you need the Envoy auth protos
compiled for your language. For Python that means generating from the
`.proto` files (`grpcio-tools` + the Envoy proto repo). Most teams
either:

1. Use a ready-made authz server (OPA, Authorino, …) — recommended.
2. Use a small Go ext-authz binary (proto stubs are already
   pre-generated upstream).

See exercise 4 for the swap.

## What the verify script demonstrates

| Step | Request                                                    | Expected         |
|------|------------------------------------------------------------|------------------|
| 1    | `/public`                                                  | 200 (filter disabled per-route) |
| 2    | `/protected` no headers                                    | 401 from authz   |
| 3    | `/protected` + `x-user-id: alice`                          | 200              |
| 4    | `/admin`     + `x-user-id: alice`                          | 403 from authz   |
| 5    | `/admin`     + `x-user-id: alice` + `x-user-role: admin`   | 200              |
| 6    | `/admin` valid → backend sees injected `x-authz-decision`  | header forwarded |
| 7    | `ext_authz.*` stats                                         | counters         |
| 8    | Stop authz container → `/protected` → 403 (failure_mode_allow: false), restart → 200 |

## Common failure modes

| Symptom                                       | Likely cause |
|-----------------------------------------------|--------------|
| Authz never sees a header your policy reads   | Missing from `authorization_request.allowed_headers`. |
| Allowed but backend doesn't see the header   | Missing from `authorization_response.allowed_upstream_headers`. |
| Every request denied while authz logs say "allow" | Authz returned a non-2xx (typo? exception?). Check `authz` logs. |
| Allow flips to deny under load               | Authz timing out past `timeout: 0.5s`. Bump the timeout or scale authz. |
| First request after `make up` is denied      | Authz container still starting. Add a healthcheck + `depends_on { condition: service_healthy }`. |

## Exercises

1. **Body-aware policy.** Configure `with_request_body: { max_request_bytes: 4096 }`
   on the filter. Update `authz/app.py` to read `request.get_data()` —
   refuse `/protected` POSTs whose body contains "forbidden-word".

2. **Cross with JWT (example 12).** Stack the two filters: `jwt_authn`
   first, then `ext_authz`. The JWT's `sub` and `role` claims get
   lifted into headers (claim_to_headers from example 12), and your
   authz policy reads them instead of trusting raw client headers.

3. **Per-vhost ext-authz.** Move the filter config from HCM to a
   virtual host's `typed_per_filter_config`. How does the inheritance
   compose with route-level overrides?

4. **gRPC swap.** Replace `http_service` with `grpc_service`, point at
   a gRPC ext-authz server (OPA with `--envoy-plugin` is the easiest
   drop-in). What does Envoy stop sending compared to HTTP-mode?

5. **failure_mode_allow trade-off.** Flip the flag to `true`,
   `make reload`. Re-run step 8 of verify. When would you accept this
   trade-off? When would you refuse it?

## Cleanup

```bash
make down
```

## What's next

- **`14-lua-filter`** — embed small bits of Lua to read / mutate
  requests without an external service.
