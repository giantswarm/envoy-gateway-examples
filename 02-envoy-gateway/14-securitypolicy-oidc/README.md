# 14 — SecurityPolicy: OIDC login flow

Same CR as example 13, different sub-feature: `oidc:` instead of
`jwt:`. Two big differences from JWT:

- **Interactive**. OIDC drives a browser-redirect dance — there's
  no "send a Bearer token" path. Sessions are kept in a cookie.
- **Needs an IdP**. We deploy [Dex](https://github.com/dexidp/dex)
  in-cluster as a tiny OIDC provider with one static user.

`make verify` confirms the policy is wired up (config landed, 302
redirect happens, `oauth2` filter present in the data plane), but
the full login flow is a manual browser step — too fragile to
script reliably (CSRF tokens, HTML forms, cookie threading).

By the end you should be able to answer:

- What does `SecurityPolicy.oidc` actually configure in Envoy?
- Why does the issuer URL appear in two places (the policy AND
  Dex's config) and how do they have to agree?
- What's the role of `backendRefs` under `provider`? Why isn't
  `issuer` enough?
- What's stored in the cookie EG sets, and how is it validated on
  subsequent requests?
- How does this differ from `jwt:` (example 13) — when do you use
  which?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–13.
- For the manual flow, ability to edit your `/etc/hosts` (or a
  browser extension that maps hostnames).

## Run it

```bash
make up           # Dex + Secret + Gateway + HTTPRoute + SecurityPolicy
make verify       # Programmatic: 302 redirect proof + oauth2 filter dump
                  # Manual:       follow the instructions printed at the end
make admin
make down
```

## The issuer URL has to resolve from THREE places

EG's translator validates the OIDC provider at policy-apply time
by fetching `<issuer>/.well-known/openid-configuration` from the
**controller pod**. Combined with the data plane and the browser,
that's three different resolvers that all have to land on the same
Dex:

```
                                                                    .
1. EG controller pod  ──► <issuer> ──► must resolve via in-cluster
   (translate-time)                    DNS to dial Dex

2. Envoy data plane   ──► <issuer> ──► must resolve via in-cluster
   (token validation)                  DNS to dial Dex's token endpoint

3. Browser            ──► <issuer> ──► must resolve via /etc/hosts
   (user login)                        + a port-forward to a host port
```

The cleanest URL that satisfies (1) and (2) is the Service's
in-cluster FQDN. We use **`http://dex.demo.svc.cluster.local:5556/dex`**
as the issuer. For (3), the user adds an entry to `/etc/hosts`
mapping that FQDN to `127.0.0.1` and port-forwards Dex to that
local port.

Cleaner-looking alternatives (a short browser-facing hostname +
`provider.backendRefs` to override the in-cluster dial) don't work
because the translator-side fetch happens BEFORE the runtime
configuration is applied — there's no `backendRefs` shortcut for
the controller's preflight check.

External IdPs (Google, Okta, Auth0) just work: their issuer URLs
resolve via public DNS from anywhere.

## The OIDC flow, step by step

```
Browser                 Envoy (Gateway)              Dex (IdP)
-------                 ---------------              ---------
GET /  ───────────────►  no session cookie
                         302 ──────────────────────► ?
                         Location: <dex>/auth?
                           client_id=envoy-gateway
                           &redirect_uri=...
                           &response_type=code
                           &scope=openid email profile
                           &state=<nonce>

(follow)                                              auth handler
                                                      ← user login form

POST /dex/auth/local                                   verify credentials
                                                       302 ───────────► ?
                                                       Location:
                                                         <app>/oauth2/callback?
                                                         code=...&state=...

GET /oauth2/callback?    OAuth2 callback handler
  code=...&state=...     (back channel via backendRefs)
                          ←── POST /dex/token ──────► token endpoint
                          ──── ID token + access ────
                         set session cookie
                         302 ──────────────────────► to original URL

GET /                    cookie matches session
                         200 + backend body ←──────── helloworld
```

`make verify` step 3 catches the first 302. Steps after that need
a real browser (or `curl --cookie-jar` with HTML-form parsing,
which is what `verify.sh` deliberately avoids).

## The pieces

```
manifests/
├── dex.yaml                  # ConfigMap (issuer, static client, static user) +
│                             #   Deployment + Service
├── dex-client-secret.yaml    # Opaque Secret with key `client-secret`
├── gateway.yaml              # Gateway 'oidc-gateway' in demo
├── httproute.yaml            # HTTPRoute, hostnames: [app.local]
└── securitypolicy.yaml       # oidc: { provider, clientID, clientSecret, ... }
```

### Things that MUST match

| Setting                                | dex.yaml                                       | securitypolicy.yaml                          |
|-----------------------------------------|------------------------------------------------|----------------------------------------------|
| Issuer URL                              | `issuer:`                                      | `oidc.provider.issuer:`                      |
| Client ID                               | `staticClients[].id`                           | `oidc.clientID:`                             |
| Client secret                           | `staticClients[].secret`                       | `dex-client-secret.yaml` `data.client-secret` |
| Redirect URI                            | `staticClients[].redirectURIs[]`               | `oidc.redirectURL:`                          |

If any of those drift, the IdP rejects the token exchange with a
descriptive error in Dex's logs — `make logs` surfaces them.

## Manual browser flow

The `verify.sh` script ends with detailed instructions, but the
short version:

```bash
# Terminal 1
make pf               # Gateway -> localhost:18150

# Terminal 2
make pf-dex           # Dex     -> localhost:5556 (same port as in-cluster)

# /etc/hosts — point both names at localhost
sudo tee -a /etc/hosts <<EOF
127.0.0.1   app.local
127.0.0.1   dex.demo.svc.cluster.local
EOF

# Browser
open http://app.local:18150/
```

You'll see:
1. Browser shows Dex's login page.
2. Log in with `admin@example.com` / `password`.
3. Browser bounces through `/oauth2/callback?code=...` and lands on
   the helloworld JSON page.
4. A cookie is now set. Reloading goes straight to the backend.

Logout: `http://app.local:18150/logout`.

## Common failure modes

| Symptom                                                                | Cause                                                                                                              |
|-------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| `SecurityPolicy Accepted=False reason: Invalid`                        | `clientSecret` Secret missing, or key isn't `client-secret`. Check `kubectl describe`.                            |
| Browser shows "redirect_uri mismatch"                                  | `redirectURL` in policy doesn't match any of Dex's `staticClients[].redirectURIs[]`. They must be byte-identical. |
| Browser shows "Invalid issuer in token"                                | Dex's `issuer:` config and SecurityPolicy `oidc.provider.issuer:` are different. They must match exactly.          |
| Login succeeds at Dex but Envoy returns 500                            | Envoy can't reach Dex's token endpoint. Check `backendRefs` points at the right Service and the Dex pod is ready. |
| Cookies aren't sticky across requests                                  | Browser session-only cookie + you're testing in incognito. Or the redirect URL host differs from the original request. |
| Dex login form returns 400 with "expired req"                          | The `req` parameter in the URL is consumed by Dex. Don't refresh the form page — restart from `/`.                |

## SecurityPolicy.oidc field reference

```yaml
oidc:
  provider:
    issuer: <url>                              # the OIDC issuer
    backendRefs: [...]                          # in-cluster Service to dial
    backendSettings: { retry, timeout, ... }   # transport tuning
  clientID: <string>
  clientSecret:
    name: <secret-name>                        # Opaque Secret with key `client-secret`
  scopes: [openid, email, profile, ...]
  resources: [...]                              # OAuth2 `resource` indicators (optional)
  redirectURL: <url>                            # must match the IdP's registered URI
  logoutPath: /logout                           # clears the session
  forwardAccessToken: true                      # add `Authorization: Bearer <access>` to upstream
  passThroughAuthHeader: true                   # don't strip incoming Authorization
  defaultTokenTTL: <duration>                   # session lifetime
  refreshToken: true                            # use refresh_token to extend sessions
  cookieDomain: <string>                        # cookie scoping
  cookieNames:
    accessToken: <string>
    idToken: <string>
  cookieConfig:
    sameSite: Strict | Lax | None
```

## OIDC vs JWT (example 13)

| Aspect                  | JWT (`jwt:`)                                | OIDC (`oidc:`)                                  |
|-------------------------|---------------------------------------------|--------------------------------------------------|
| Auth mechanism          | Bearer token in `Authorization` header     | Browser redirect + session cookie               |
| Token issued by         | Anyone (you, Auth0, Cognito, …)            | The configured IdP                              |
| Validation              | Signature + claims (local check)            | IdP also issues; Envoy validates ID token        |
| User-visible login flow | None — caller already has a token          | Yes — browser bounces through IdP login         |
| Use when                | Service-to-service, API clients, mobile     | Browser-based apps with humans                   |
| Combine?                | Yes — JWT for API paths, OIDC for browser paths (two policies + path matchers) |

## Exercises

1. **Forward the access token.** Set
   `forwardAccessToken: true`. Inspect helloworld's `/echo` to
   see the `Authorization: Bearer <access>` header arrive
   upstream. What's the access token format? Decode it with `jq`.

2. **Custom cookie domain.** Add another HTTPRoute for
   `another.local` and set `cookieDomain: .local` so the cookie
   is valid across both hosts. Verify by logging in via `app.local`,
   then hitting `another.local` and confirming you're not asked to
   log in again.

3. **Refresh tokens.** Enable `refreshToken: true` and reduce
   `defaultTokenTTL` to `1m`. After login, wait 90s, hit the
   Gateway again. Envoy should silently use the refresh token to
   extend the session, no re-login required.

4. **External IdP.** Replace the in-cluster Dex with a real
   external IdP (Google, GitHub OAuth, or a hosted Dex). Update
   `issuer`, drop `backendRefs` (so Envoy dials the public URL),
   register the client + redirect URI at the IdP.

5. **Stack with JWT.** Add a second SecurityPolicy targeting a
   `/api` HTTPRoute, using `jwt:` instead of `oidc:`. Same
   Gateway. Browser users get OIDC; API clients send Bearer JWTs.
   Confirm both paths work without interference.

## Cleanup

```bash
make down
# /etc/hosts edits stay; remove them manually if you added them.
```

## What's next

- [`15-securitypolicy-basicauth-cors-ipallow`](../15-securitypolicy-basicauth-cors-ipallow/)
  — smaller SecurityPolicy features grouped: basic auth, CORS,
  IP allow/deny. All cookie-/header-driven, no IdP needed.
