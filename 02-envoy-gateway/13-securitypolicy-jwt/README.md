# 13 — SecurityPolicy: JWT validation

Phase 2's answer to [Phase 1 example 12](../../01-envoy-proxy/12-jwt-authn/).
Same backend, same JWT signing helper, same Envoy filter under the
hood — but now the configuration is a single `SecurityPolicy` CR
attached to an HTTPRoute, not a hand-rolled HCM filter chain.

`SecurityPolicy` is EG's umbrella CR for downstream-AuthN/Z:

- `jwt:` — JWT validation (this example)
- `oidc:` — OIDC login flow (example 14)
- `basicAuth:` — HTTP basic-auth (example 15)
- `cors:` — CORS (example 15)
- `authorization:` — client IP allow/deny rules (example 15)
- `extAuth:` — external authorization service (example 16)

You can mix multiple sub-features in one SecurityPolicy. We stick
to just `jwt:` here.

By the end you should be able to answer:

- What does `SecurityPolicy.jwt` actually validate? Where in the
  filter chain does it run?
- What's the difference between `localJWKS` and `remoteJWKS`?
- How does `claimToHeaders` work — what does the backend see?
- What does a rejected token look like to the client?
- How does EG's SecurityPolicy compare to writing raw
  `envoy.filters.http.jwt_authn` config (Phase 1 ex 12)?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–12.
- `openssl` and `jq` on your `$PATH`.

## Run it

```bash
make up           # gen-keys.sh, render & apply SecurityPolicy
make verify       # 9-section walk — 5 token scenarios + filter inspection
make admin
make down
```

## How the JWKS gets into the policy

`SecurityPolicy.spec.jwt.providers[].localJWKS.inline` takes the
JWKS as a **string** (a one-line JSON document). The flow:

1. `gen-keys.sh` produces `keys/private.pem`, `keys/public.pem`,
   and `keys/jwks.json` (idempotent).
2. `manifests/securitypolicy.yaml` ships with `__JWKS_INLINE__` as
   a placeholder.
3. `make up` substitutes the placeholder with `jq -c . keys/jwks.json`
   before piping to `kubectl apply`. The `|` sed delimiter avoids
   conflict with JSON `/`; the YAML single-quote wrapper preserves
   JSON's double-quotes literally.

The rendered SecurityPolicy is what actually lives in the cluster.
You can inspect it with `kubectl -n demo get securitypolicy
jwt-protect -o yaml`.

## Two ways to supply the JWKS

```yaml
jwt:
  providers:
    - name: ...
      issuer: ...
      audiences: [...]

      # Option A — inline (this example)
      localJWKS:
        inline: '{"keys":[...]}'

      # Option B — remote
      remoteJWKS:
        uri: https://issuer.example.com/.well-known/jwks.json
        # Envoy fetches and caches, refreshing on a TTL or 401 from
        # the validator. Good for keys that rotate.
```

| Choice         | Pros                                         | Cons                                                                |
|----------------|----------------------------------------------|---------------------------------------------------------------------|
| `localJWKS`    | Self-contained, no extra deps, hermetic test | Rotation requires re-applying the CR                                |
| `remoteJWKS`   | Picks up issuer's key rotation automatically | Network dependency; cluster needs egress + DNS to the issuer       |

Production almost always uses `remoteJWKS`. Tutorials use
`localJWKS` so you don't need a separate issuer pod.

## Claim extraction → backend headers

```yaml
claimToHeaders:
  - claim: sub
    header: x-user
  - claim: aud
    header: x-aud
```

After Envoy validates the token, it copies the named claim into
the named request header. The **backend** sees these as ordinary
HTTP headers — typically used for authorization checks downstream
(your service reads `x-user` and looks them up in your DB).

In this example the helloworld backend echoes back what it
received; `make verify` step 4 prints both `x-user` and `x-aud`.

## What a rejected request looks like

The Envoy `jwt_authn` filter short-circuits on missing/invalid
tokens. The client gets HTTP 401 with a body like:

```
Jwt is missing
```

or

```
Jwt verification fails
```

— useful enough to debug with, but if you need a nicer error
shape, layer an `extAuth` SecurityPolicy (example 16) or shape the
response with a `responseOverride` field.

## The pieces

```
manifests/
├── gateway.yaml             # Gateway 'jwt-gateway' in demo
├── httproute.yaml           # HTTPRoute 'jwt-protect' -> helloworld
└── securitypolicy.yaml      # has __JWKS_INLINE__ placeholder
```

`gen-keys.sh` produces the RSA keypair and the JWKS.
`mint-token.sh` signs JWTs with overrideable claims (used by
`verify.sh`).

## Verify

`make verify` walks through:

1. CTP/BTP/SP Accepted=True, Gateway Programmed.
2. Port-forward.
3. **No token** → expect 401.
4. **Valid token** → 200 + the backend sees `x-user: alice`,
   `x-aud: api.local`.
5. **Expired token** (`exp=100`) → 401.
6. **Wrong audience** (`aud=other-service`) → 401.
7. **Wrong issuer** (`iss=https://bad-issuer...`) → 401.
8. `/config_dump` extract: list HCM filters (find `jwt_authn`),
   then the provider's `issuer` + `audiences`.
9. SecurityPolicy.jwt → Envoy artifact mapping table.

## Common failure modes

| Symptom                                                           | Cause                                                                                                       |
|--------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| Every request returns 401 even with what looks like a valid token | Token's `iss` doesn't match the policy's `issuer:`. Inspect the token's payload with `echo "$token" | cut -d. -f2 | base64 -d | jq`. |
| Expired token returns 200 anyway                                  | `exp` claim missing — the validator doesn't enforce expiry on tokens with no `exp`. Always include one.    |
| Backend doesn't see `x-user`                                      | `claimToHeaders[].claim` doesn't match a top-level claim in the JWT. Nested claims aren't supported in v1alpha1; use a flat claim. |
| SecurityPolicy `Accepted=False reason: Invalid`                   | `localJWKS.inline` isn't a string OR isn't valid JWKS JSON. Validate with `jq '.' < keys/jwks.json`.       |
| SecurityPolicy `Conflicted=True`                                  | Two SecurityPolicies target the same route. Merge them.                                                    |
| `remoteJWKS` set, fetches but every request 401s                  | Issuer's JWKS uses an `alg` Envoy doesn't support (rare), or the response Content-Type isn't JSON. Curl the URI manually to inspect. |
| Token works in curl, fails in a browser                           | Browsers send tokens via cookies / OIDC, not `Authorization: Bearer`. Use the OIDC flow (example 14).      |

## Exercises

1. **Multiple audiences.** Add a second `audiences:` entry
   (`internal.local`). Mint tokens with each audience and verify
   both reach the backend. Mint one with `aud=other` and verify
   it's still rejected.

2. **Claim-based routing.** Set `recomputeRoute: true` and add a
   second HTTPRoute that matches on header `x-user: alice`
   (extracted by `claimToHeaders`). Confirm Alice and Bob land on
   different backends.

3. **Remote JWKS.** Deploy a tiny nginx pod serving the same
   `jwks.json` over HTTP. Switch `localJWKS` for
   `remoteJWKS.uri: http://jwks-server.demo.svc.cluster.local/jwks.json`.
   Verify the same tokens still validate. Bonus: stop the JWKS
   server and watch tokens start failing.

4. **Multiple providers.** Add a second `providers[]` entry with
   a different issuer + JWKS (generate a second keypair). Tokens
   from either issuer should be accepted.

5. **Bind to a single rule.** Today the SecurityPolicy targets the
   whole HTTPRoute. Split into two routes (`/public` and
   `/private`), only protect the latter. Confirm `/public`
   requires no token while `/private` does.

## Cleanup

```bash
make down
make clean-keys
```

## What's next

- [`14-securitypolicy-oidc`](../14-securitypolicy-oidc/) — OIDC
  login flow with Dex or Keycloak in-cluster. Same SecurityPolicy
  CR, different sub-feature.
