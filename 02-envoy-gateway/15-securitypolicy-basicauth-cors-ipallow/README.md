# 15 — SecurityPolicy: basic auth + CORS + IP allowlist

Three smaller SecurityPolicy sub-features grouped into one example
to show they can stack in a single CR. Same SP machinery as JWT
(ex 13) and OIDC (ex 14) — different sub-blocks.

What we wire up:

- **`basicAuth`** — username/password from an htpasswd-format Secret.
- **`cors`** — Cross-Origin Resource Sharing for browser apps.
- **`authorization`** — IP CIDR allow/deny rules. Combined with a
  `ClientTrafficPolicy` so the source IP is taken from
  `X-Forwarded-For`.

By the end you should be able to answer:

- What format does `basicAuth.users` expect (and how is the
  htpasswd Secret structured)?
- How does `cors` interact with auth? Does the preflight need
  credentials?
- What does `authorization.principal.clientCIDRs` match against —
  the raw remote address or XFF?
- In what order do these three filters run in Envoy's HCM?
- How would you split this into multiple SecurityPolicies if you
  wanted per-route variations?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–14.

## Run it

```bash
make up           # Secret + Gateway + HTTPRoute + CTP + SP
make verify       # 9 sections: status, port-forward, 6 scenarios, mapping
make admin
make down
```

## The htpasswd Secret

```yaml
type: Opaque
stringData:
  .htpasswd: |
    alice:{SHA}<base64(sha1(password))>
```

- Key MUST be `.htpasswd` (literal dot prefix — easy to miss).
- **Format is SHA-1, NOT bcrypt.** Envoy's basic_auth filter only
  accepts the `{SHA}...` (RFC2307) hash format. Bcrypt hashes
  (`$2a$10$...`) — the modern default of every other tool — are
  rejected at xDS push time with `unsupported htpasswd format:
  please use {SHA}`, which manifests as the listener failing to
  load (Envoy looks like it's crashing on the first request).
- Generate hashes with: `htpasswd -nbs <user> <password>`
  (note `-s`, not `-B`). Each line is `username:{SHA}<hash>`.

In the manifest we ship a single user: `alice` / `password`
(`{SHA}W6ph5Mm5Pz8GgiULbPgzG37mj9g=` is SHA-1 of `password`).

Verify with: `curl -u alice:password http://localhost:18160/`.

Add more users by appending lines (one per user).

## CORS

```yaml
cors:
  allowOrigins:
    - https://app.example.com
    - https://*.partners.example.com
  allowMethods: [GET, POST, OPTIONS]
  allowHeaders: [authorization, content-type, x-custom-header]
  exposeHeaders: [x-response-time]
  maxAge: 1h
  allowCredentials: true
```

- `allowOrigins` accepts exact strings and wildcards (`*.foo.com`).
  `"*"` is allowed but mutually exclusive with `allowCredentials: true`.
- `allowHeaders` must include `authorization` if browser apps need
  to send basic-auth or OIDC cookies — otherwise the preflight
  fails before the auth filter even runs.
- `maxAge:` caches the preflight response in browsers, reducing
  OPTIONS spam.
- The CORS filter runs **before** authentication. Preflight OPTIONS
  requests are answered by the CORS filter directly; the backend
  never sees them.

## Authorization (IP allow/deny)

```yaml
authorization:
  defaultAction: Deny           # anything not matched -> 403
  rules:
    - name: allow-internal
      action: Allow
      principal:
        clientCIDRs:
          - 10.0.0.0/8
          - 172.16.0.0/12
          - 192.168.0.0/16
    - name: allow-loopback
      action: Allow
      principal:
        clientCIDRs:
          - 127.0.0.0/8
```

- `defaultAction: Deny` is the safer pattern — explicit allows only.
  Flip to `Allow` for a denylist instead.
- Rules are evaluated **in order**; first match wins. Put narrower
  rules first.
- `clientCIDRs` is matched against **what Envoy considers the
  client's IP**. By default that's the immediate TCP peer (the
  kubectl port-forward in this demo). To match the real client
  through a proxy, configure
  `ClientTrafficPolicy.clientIPDetection.xForwardedFor.numTrustedHops`
  — exactly what we do in `manifests/clienttrafficpolicy.yaml`.

Without the CTP, the only matchable source would be `127.0.0.1`
(from kubectl), which makes the IP-allow demo pointless.

## How the three compose

In Envoy's HCM filter chain (after EG's translation):

```
client request
   ↓
   cors filter            ← OPTIONS preflight short-circuits here
   ↓                       ← non-preflight requests: just attach CORS response headers
   rbac filter            ← IP allow / deny (authorization sub-feature)
   ↓
   basic_auth filter      ← username/password check
   ↓
   router → backend
```

So a request must pass IP allowlist AND basic auth to reach the
backend. CORS doesn't gate non-preflight traffic; it just adds
response headers and handles preflights.

## The pieces

```
manifests/
├── gateway.yaml
├── httproute.yaml
├── basic-auth-secret.yaml      # Opaque Secret with .htpasswd key
├── clienttrafficpolicy.yaml    # XFF trust hop = 1 (so IP allow works via curl)
└── securitypolicy.yaml         # cors + authorization + basicAuth
```

## Verify scenarios

`make verify` runs 9 sections:

1. CRs all Accepted.
2. Port-forward.
3. **No creds + allowed XFF** → 401 (basic auth).
4. **Wrong creds + allowed XFF** → 401.
5. **Right creds + allowed XFF** → 200; backend sees the
   Authorization header.
6. **Right creds + denied XFF (`8.8.8.8`)** → 403 (IP block).
7. **CORS preflight from allowed origin** → 200 with
   `Access-Control-Allow-Origin: https://app.example.com`.
8. **CORS preflight from disallowed origin** → no
   `Access-Control-Allow-Origin` header (browser would block).
9. `/config_dump`: list the HCM filters in order, mapping table
   for each sub-feature.

## Common failure modes

| Symptom                                                                  | Cause                                                                                                            |
|---------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------|
| All requests return 403, even with correct creds + allowed XFF            | `numTrustedHops: 1` not set in CTP, so Envoy uses 127.0.0.1 (loopback) as the source — NOT in any allow rule. Or the loopback rule was removed. |
| Basic auth always returns 401 even with right creds                       | Secret key isn't `.htpasswd` (note the dot), OR hash uses the wrong format. Envoy wants `{SHA}<base64(sha1(pw))>` only — bcrypt is REJECTED. Generate with `htpasswd -nbs`. |
| Listener errors `unsupported htpasswd format: please use {SHA}`, all requests return "Empty reply" | Bcrypt hash used instead of SHA-1. Switch to `htpasswd -nbs` (SHA-1). |
| CORS preflight returns no headers from an "allowed" origin                | `allowOrigins` matches case-sensitively. `https://APP.EXAMPLE.COM` won't match `https://app.example.com`.        |
| Browser console: "Response to preflight request doesn't pass access control" | `Access-Control-Request-Headers` includes a header not in `allowHeaders`. Add it. Common: `authorization`, `content-type`. |
| `allowCredentials: true` + `allowOrigins: ["*"]` → SecurityPolicy invalid | Spec disallows the combination. Use specific origins when sending creds.                                          |
| Two SecurityPolicies on the same route                                    | Conflicted. Merge into one SP with multiple sub-features, like this example.                                     |

## Exercises

1. **Per-path basic auth.** Split the HTTPRoute into two rules,
   `/public/*` and `/private/*`. Move basicAuth to a SECOND
   SecurityPolicy targeting only the `/private` HTTPRoute. Verify
   `/public` works without creds and `/private` doesn't.

2. **OAuth2 / JWT instead of basic.** Replace `basicAuth` with
   `jwt:` from example 13. Same CR, just a different sub-block.
   IP allowlist and CORS remain in place.

3. **CORS wildcard.** Add a second exact origin AND a wildcard
   (`https://*.partners.example.com`). Test preflights from
   `https://acme.partners.example.com` (allowed) and
   `https://bad.example.com` (denied).

4. **Denylist by header.** EG `authorization` rules can also use
   `headers:` to match. Add a rule denying requests where header
   `x-blocked-tenant=true`. Test with `curl -H 'x-blocked-tenant: true'`.

5. **Deny + Allow ordering.** Add an explicit Deny rule for
   `10.99.0.0/16` BEFORE the broad Allow for `10.0.0.0/8`. Verify
   that `10.99.0.5` gets 403 even though `10.99.0.0/16` ⊂
   `10.0.0.0/8`.

## Cleanup

```bash
make down
```

## What's next

- [`16-securitypolicy-extauth`](../16-securitypolicy-extauth/) —
  external authorization service. The most powerful (and most
  customizable) SecurityPolicy sub-feature: delegate the decision
  to your own HTTP/gRPC service.
