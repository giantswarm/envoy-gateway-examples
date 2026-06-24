# 16 — SecurityPolicy: external authorization

Phase 2's answer to [Phase 1 example 13](../../01-envoy-proxy/13-ext-authz/).
Same toy authz service (`authz/app.py`), same toy policy — but now
wired up via `SecurityPolicy.extAuth` instead of a hand-written
`envoy.filters.http.ext_authz` block.

`extAuth` is the SecurityPolicy sub-feature for delegating the
decision to **your own** service. Where `jwt:` validates a token,
`oidc:` does the login dance, `basicAuth:` checks an htpasswd
file, and `authorization:` matches CIDRs — `extAuth:` says
"call this service and do whatever it tells you". Use when no
built-in mechanism captures your policy logic.

By the end you should be able to answer:

- What goes over the wire from Envoy to the authz service?
- What does the authz service control by its response (status,
  headers, body)?
- What's `failOpen`, when do you want each setting, what's the
  default?
- How does extAuth compose with the other SecurityPolicy
  sub-features?
- When use HTTP vs gRPC?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–15.
- `docker` + `kind` (to build + load the authz image).

## Run it

```bash
make up           # docker build + kind load + apply everything
make verify       # 9 sections, including a live "kill authz, watch fail-closed" test
make admin
make down
```

## How the authz call works

```
Client                          Envoy                          Authz pod
------                          -----                          ---------
GET /protected/profile ──────►  receives request
x-user-id: alice                 │
                                 │  ext_authz filter pauses    
                                 │  the request and dials authz
                                 │
                                 ├──► GET /protected/profile ─►  reads x-user-id,
                                 │     x-user-id: alice          decides allow
                                 │                               ◄── 200, x-authz-decision: ...
                                 │  authz returned 2xx -> allow.
                                 │  headersToBackend: [x-authz-decision]
                                 │  -> inject x-authz-decision
                                 │     onto the original request
                                 │
                                 ├──► forward original request ──► helloworld
                                 │     + x-authz-decision: ...
                                 │                                  ◄── 200
                                 ◄── 200
   ◄── 200 to client
```

If authz returns non-2xx, Envoy returns that status to the client
and never calls the backend. Body/headers from the deny response
can be propagated too — covered in EG's `authorizationResponse` knob.

## The toy authz policy

`authz/app.py` (reused verbatim from Phase 1 ex 13):

| Path prefix     | Allowed when                          | Returns                                            |
|-----------------|---------------------------------------|----------------------------------------------------|
| `/admin/*`      | `x-user-role: admin`                  | 200 + `x-authz-decision: admin-allowed`            |
| `/protected/*`  | `x-user-id: <non-empty>`              | 200 + `x-authz-decision: allowed-for-<user>`       |
| everything else | always                                | 200 + `x-authz-decision: unmetered`                |

Real authz services would do more: look up tenants, parse JWTs,
call OPA, evaluate role hierarchies, etc. The pattern is identical
— this one's just slim.

## SecurityPolicy.extAuth shape

```yaml
extAuth:
  # Pick exactly one transport: http or grpc.
  http:
    backendRefs: [{ name: authz, port: 8000 }]
    path: /verify                    # optional; defaults to the original path
    headersToBackend:                # authz response headers -> upstream request
      - x-authz-decision
    headersToExtAuth:                # client headers -> authz (default: all)
      - authorization
      - x-user-id
      - x-user-role
    bodyToExtAuth:                   # forward part of the body to authz
      maxRequestBytes: 0             # 0 = don't forward

  # Alternative:
  # grpc:
  #   backendRefs: [{ name: opa, port: 9191 }]
  # The gRPC variant uses Envoy's CheckRequest protobuf — more
  # efficient, type-safe, but requires the authz service to speak
  # the protocol.

  failOpen: false                    # default — fail-closed (deny on authz down)
```

`failOpen: false` (the default) is the safe choice. Flipping to
`true` means "if authz is unreachable, let the request through" —
nice for availability, terrifying for security. Be explicit.

## Choosing HTTP vs gRPC ext_authz

| Aspect              | HTTP                                         | gRPC                                                |
|---------------------|----------------------------------------------|-----------------------------------------------------|
| Implementation cost | Any HTTP framework (Flask, Express, etc.)    | Need an Envoy CheckRequest protobuf server         |
| Per-request overhead| Higher (HTTP/1.1 reuse, header parsing)      | Lower (HTTP/2 streams, protobuf)                   |
| Visibility          | Plain HTTP — easy to debug with curl + logs  | gRPC — needs `grpcurl describe` & friends           |
| Body forwarding     | Up to `maxRequestBytes`                       | Streamed via gRPC                                   |
| Production fit      | Low/moderate QPS, prototyping, custom logic  | High-QPS edges, OPA, Cerbos, sidecar authz         |

This tutorial uses HTTP because the authz code is shorter. For real
work at scale, gRPC is usually the choice.

## The pieces

```
authz/
├── app.py             # Flask service implementing the toy policy
└── Dockerfile         # python:3.12-slim + flask, listens on :8000

manifests/
├── authz.yaml         # Deployment + Service in demo namespace
├── gateway.yaml       # Gateway 'extauth-gateway'
├── httproute.yaml     # HTTPRoute -> helloworld
└── securitypolicy.yaml # extAuth.http with backendRefs to authz
```

`make image` builds + `kind load`s the authz image (no registry).
`make up` runs `make image` first, then applies manifests in
dependency order (authz up → policy applied).

## Verify steps

`make verify` runs 9 sections:

1. CRs Accepted + authz Deployment Ready.
2. Port-forward.
3. **Unmetered path** (`/echo`) → 200.
4. **`/protected/foo` without `x-user-id`** → 401.
5. **`/protected/profile` with `x-user-id: alice`** → 200, backend
   sees `x-authz-decision: allowed-for-alice`.
6. **`/admin/settings` without `x-user-role: admin`** → 403.
7. **`/admin/settings` with `x-user-role: admin`** → 200, backend
   sees `x-authz-decision: admin-allowed`.
8. **Fail-closed test**: scale authz to 0, watch all traffic get
   non-2xx (because `failOpen: false`). Scale back, recover.
9. `/config_dump` extract of the `ext_authz` filter config.

## Common failure modes

| Symptom                                                                  | Cause                                                                                            |
|---------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `SecurityPolicy Accepted=False reason: Invalid backendRef`               | The Service named in `backendRefs` doesn't exist or is in another namespace without a `ReferenceGrant`. |
| All traffic gets 403 even on "unmetered" paths                            | authz pod returned non-2xx for that path. Check `kubectl -n demo logs deploy/authz`.            |
| Backend doesn't see `x-authz-decision`                                    | Header not in `headersToBackend`. Add it.                                                       |
| Authz never sees `x-user-id`                                              | `headersToExtAuth` is set but doesn't include it. Either expand the allowlist or unset (= all). |
| With authz down, traffic still flows                                      | `failOpen: true` was set. Set it to `false` (or omit — default is false).                       |
| With authz down, ALL traffic fails — including health checks             | That's `failOpen: false` working as designed. If you need probes to bypass the policy, attach a separate HTTPRoute for `/healthz` and don't apply the SP to it. |
| Per-RPC latency went up after enabling extAuth                            | Authz call is on the critical path. Use gRPC variant + connection pooling + tune timeout/retry. |

## Exercises

1. **Per-tenant rate limit.** Replace the toy authz with one that
   reads `x-tenant` and consults Redis to track requests per tenant.
   Return 429 when over budget. (Or just use
   [`19-rate-limiting`](../19-rate-limiting/) — but understanding
   how it'd look behind extAuth is illuminating.)

2. **Body inspection.** Set `bodyToExtAuth.maxRequestBytes: 4096`,
   then make the authz service parse the JSON body and inspect a
   field. POST a payload and confirm a "valid" body gets through
   while a "denied" one returns 403.

3. **Combine with JWT.** Add a `jwt:` block to the same
   SecurityPolicy. Envoy validates the JWT first (cheap, local),
   then if it passes, calls extAuth (expensive, network). Have
   authz read the JWT claims via `headersToExtAuth: [authorization]`.

4. **gRPC ext_authz.** Switch to the gRPC variant. Use
   [open-policy-agent/opa-envoy-plugin](https://github.com/open-policy-agent/opa-envoy-plugin)
   or [cerbos/cerbos](https://github.com/cerbos/cerbos) as the
   backend. Write the same toy policy in Rego or Cerbos YAML.

5. **failOpen vs failClosed trade-off.** Set `failOpen: true` and
   re-run section 8. What's the user impact? When is each setting
   the right call? (Hint: depends on what "deny by default"
   means for your product.)

## Cleanup

```bash
make down
```

## What's next

- [`17-envoyextensionpolicy-wasm-lua`](../17-envoyextensionpolicy-wasm-lua/)
  — EG's blessed way to attach Wasm/Lua filters (mirrors Phase 1
  ex 15).
