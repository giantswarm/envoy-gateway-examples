# 12 — JWT authentication

Envoy validates JWTs in-line via the `envoy.filters.http.jwt_authn`
filter. Configure a **provider** (issuer, audiences, JWKS source) and a
list of **rules** that say which routes need which provider. Optionally
forward the original token or specific claims to the upstream as
headers.

By the end of this example you should be able to answer:

- Where does `jwt_authn` live in the filter chain?
- What does `local_jwks` look like and what's the structure of a JWKS?
- How do `providers` and `rules` compose?
- What's `requires_all` vs `requires_any` vs a bare `provider_name`?
- How do I forward claims to the upstream so the backend doesn't need
  to re-validate?
- How do I plug in a real IdP (`remote_jwks`)?

## Prerequisites

- Done [`01`](../01-helloworld-static/) through
  [`11`](../11-rate-limiting-global/).
- Docker, `docker compose`, `openssl`, `curl`, `jq`.

## Run it

```bash
make up           # generates keys/jwks.json + keys/private.pem, then starts
make verify       # nine scenarios from "no token" to "claim forwarding"
make token        # print a fresh valid token
make down

# Mint custom tokens manually:
SUB=bob EXTRA='{"role":"admin"}' ./mint-token.sh
EXP=100 ./mint-token.sh   # expired
ISS=other ./mint-token.sh # wrong issuer
```

`make up` runs `gen-keys.sh` which:

1. Generates an RSA-2048 keypair.
2. Writes `keys/private.pem` (used by `mint-token.sh` to sign) and
   `keys/jwks.json` (mounted into Envoy at `/etc/envoy/keys/jwks.json`).

Both files are `.gitignored`. `mint-token.sh` builds compact-serialized
JWTs in pure bash + `openssl` + `jq`.

## Providers and rules

The filter has two top-level fields:

```yaml
providers:
  demo:
    issuer: "envoy-demo"
    audiences: ["hello"]
    local_jwks: { filename: /etc/envoy/keys/jwks.json }
    forward: true
    forward_payload_header: "x-jwt-payload"
    claim_to_headers:
      - { header_name: x-jwt-sub,  claim_name: sub }
      - { header_name: x-jwt-role, claim_name: role }
rules:
  - match: { prefix: "/private" }
    requires: { provider_name: demo }
  - match: { prefix: "/claims" }
    requires: { provider_name: demo }
```

**Providers** = the set of acceptable token issuers, each with a JWKS
source and validation knobs. **Rules** = which routes require which
provider.

> **Rules use their own match block.** `jwt_authn`'s `rules` are NOT
> the same as route matches — they're internal to the filter. A
> request must satisfy both the route table *and* a rule's match to
> trigger validation. Routes without a matching rule pass through with
> no JWT check.

### `requires` shapes

```yaml
# Single provider
requires: { provider_name: idp_a }

# All of multiple providers (rare — chained validators)
requires:
  requires_all:
    requirements:
      - provider_name: idp_a
      - provider_name: idp_b

# Any of multiple providers (federation — accept tokens from either IdP)
requires:
  requires_any:
    requirements:
      - provider_name: idp_a
      - provider_name: idp_b

# Allow missing JWT (auth is optional but if present must be valid)
requires:
  requires_any:
    requirements:
      - provider_name: idp_a
      - allow_missing: {}
```

That last one is the classic "logged-in users see more, anonymous users
still allowed" pattern.

## What a provider validates

The filter enforces:

- **Signature** — using the matching JWK from the JWKS (looked up by
  `kid` if the token has one, else by `alg` + `use`).
- **`iss`** — must equal the provider's `issuer`.
- **`aud`** — must include one of the provider's `audiences` (if you
  declared any; omit to skip).
- **`exp`** — must be in the future.
- **`nbf`** — must be in the past (if present).

If any check fails, Envoy returns `401 Unauthorized` with a
`www-authenticate` header and **never invokes the upstream**.

Things `jwt_authn` does NOT check:

- Token scope, roles, or other authorization claims. Use ext-authz
  (next example) for that.
- Revocation — JWTs are stateless. For "log this user out now" you
  want an external authz service that consults a revocation list.
- Per-method or per-resource access rules. Same — that's authz.

## JWKS sources

```yaml
local_jwks: { filename: /etc/envoy/keys/jwks.json }
# or
local_jwks: { inline_string: '{"keys":[...]}' }
# or — the real-world one:
remote_jwks:
  http_uri:
    uri: "https://idp.example.com/.well-known/jwks.json"
    cluster: idp_cluster
    timeout: 5s
  cache_duration: 600s
  async_fetch: { fast_listener: true }
```

For `remote_jwks` you also need a cluster pointing at the IdP. Envoy
fetches the JWKS at startup and refreshes it on `cache_duration`.

> **Watch for clock skew.** A common production bug: the IdP's
> `exp` lookahead and Envoy's host clock disagree by a few seconds,
> tokens silently become "expired" the moment they're minted. Either
> sync clocks (NTP) or set `clock_skew_seconds: N` on the provider.

## Forwarding tokens and claims

```yaml
forward: true                         # leave Authorization header in place
forward_payload_header: "x-jwt-payload"   # extra header with base64url payload
claim_to_headers:                     # individual claim -> header
  - { header_name: x-jwt-sub,  claim_name: sub }
  - { header_name: x-jwt-role, claim_name: role }
```

Three patterns, pick what your backend needs:

1. **Backend re-validates** — set `forward: true`, leave it alone. Most
   secure (defense in depth), but every backend has to know how to
   validate.
2. **Backend trusts Envoy** — set `forward: false`, use `claim_to_headers`
   for the few claims the backend reads. Simpler app code, tighter
   coupling to Envoy's validation.
3. **Hybrid** — set `forward_payload_header: x-jwt-payload`. Backend
   reads claims from the base64url JSON without re-validating; if it
   needs to validate, it still can (but the payload-only header has
   no signature, so the backend would need the original Authorization).

## What the verify script demonstrates

| Step | Request                                       | Expected |
|------|-----------------------------------------------|----------|
| 1    | `/public`                                     | 200      |
| 2    | `/private` (no token)                         | 401      |
| 3    | `/private` with `Bearer not.a.jwt`            | 401      |
| 4    | `/private` with an expired token              | 401      |
| 5    | `/private` with wrong `iss`                   | 401      |
| 6    | `/private` with wrong `aud`                   | 401      |
| 7    | `/private` with a valid token                 | 200      |
| 8    | `/claims` with a valid token (role=admin)     | 200, plus the backend sees `x-jwt-sub`, `x-jwt-role`, and decoded `x-jwt-payload` |
| 9    | `/stats?filter=jwt_authn`                     | Per-provider counters |

The relevant stats:

```
http.ingress_http.jwt_authn.allowed
http.ingress_http.jwt_authn.denied
http.ingress_http.jwt_authn.jwks_fetch_success / _failure
http.ingress_http.jwt_authn.jwt_cache_hit  / _miss
```

## Common failure modes

| Symptom                                          | Likely cause                                                       |
|--------------------------------------------------|--------------------------------------------------------------------|
| Every valid-looking token returns 401            | `iss` / `aud` mismatch; check the actual claims with `jwt-decode`. |
| Tokens "expired" the moment they're minted       | Clock skew between client and Envoy. Set `clock_skew_seconds: 30`. |
| Tokens missing `kid` fail                        | Filter falls back to alg matching; set the right `alg` in your JWKS keys. |
| `remote_jwks` never works                        | Cluster missing HTTP/2 options, or DNS/CA path broken. Check `cluster.idp.upstream_rq_total`. |
| Some routes inexplicably skip auth               | `rules:` match block doesn't cover them. `jwt_authn` rules use their OWN match grammar. |

## Exercises

1. **Federation.** Add a second provider `partner` with a different
   issuer and JWKS, and switch the rule to `requires_any: [demo, partner]`.
   Mint tokens for both and verify they're accepted.

2. **`allow_missing` for soft auth.** Add `requires_any` with
   `provider_name: demo` and `allow_missing: {}` on `/public`. The
   route now lets anonymous callers in, but if a JWT is present it
   must be valid. Confirm `Authorization: Bearer garbage` is rejected
   even on `/public`.

3. **Claim-based authz with header_value_match.** Combine `claim_to_headers`
   with example 03's `header_value_match` action: only let `role=admin`
   tokens reach `/admin`. (This is a precursor to the full RBAC story
   in example 13.)

4. **`remote_jwks` against a real IdP.** Point a provider at a Keycloak
   or Auth0 tenant's `/.well-known/jwks.json`. You'll need a cluster
   with the IdP's hostname, HTTP/2 options, and (if HTTPS)
   `transport_socket: { tls: { ... } }`. Watch the
   `jwks_fetch_success/_failure` stats during startup.

5. **Rotate the key.** Edit `keys/jwks.json` and add a SECOND key with
   a fresh `kid`. Mint a token signed by the new private key (you'll
   need to add `kid` plumbing to `mint-token.sh`). Verify both old and
   new tokens are accepted — that's how IdPs roll keys without
   downtime.

## Cleanup

```bash
make down
make clean-keys    # optional — keys regenerated next `make up`
```

## What's next

- **`13-ext-authz`** — the `ext_authz` filter. Off-loads the
  *authorization* decision to a small gRPC service so policy doesn't
  have to live in Envoy YAML.
