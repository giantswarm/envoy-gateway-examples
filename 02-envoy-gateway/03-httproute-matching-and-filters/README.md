# 03 — HTTPRoute matching and filters

Phase 2's answer to [Phase 1 example 03](../../01-envoy-proxy/03-routing-basics/).
We grow the route table from "everything → backend" into the realistic
shape: prefix vs exact vs regex matches, header- and query-gated
routes, URL rewrites, redirects, and per-route header manipulation.

Plus a **second HTTPRoute attached to the same Gateway** that scopes
its rules to a specific `Host` header — Gateway API's equivalent of
Phase 1's second virtual host.

By the end of this example you should be able to answer:

- What match types does Gateway API support and how do they compose
  inside a rule vs across rules?
- Which `filters[]` does plain HTTPRoute give you, and which features
  require an `HTTPRouteFilter` / `SecurityPolicy` / `EnvoyPatchPolicy`?
- How does rule ordering work?
- How do multiple HTTPRoutes attaching to one Gateway merge?
- What does the generated Envoy `RoutesConfigDump` look like?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done [`01-helloworld-gateway`](../01-helloworld-gateway/) and
  [`02-egctl-and-config-dump`](../02-egctl-and-config-dump/).

## Run it

```bash
make up           # apply Gateway + both HTTPRoutes, wait for Programmed/Accepted
make verify       # 9-step walkthrough exercising every rule
make admin        # port-forward Envoy admin endpoint in another terminal
make down
```

## The HTTPRoute matching grammar

```yaml
rules:
  - matches:                 # OR
      - path:                # ALL of path / headers / queryParams / method on this match
          type: PathPrefix|Exact|RegularExpression
          value: ...
        headers:
          - { name, type: Exact|RegularExpression, value }
        queryParams:
          - { name, type: Exact|RegularExpression, value }
        method: GET|POST|...
      - path: ...            # alternative match
    filters: [...]           # see next section
    backendRefs: [...]       # the upstream(s) — weighted if multiple
```

- **Within one `matches[]` entry**, fields are AND-ed.
- **Across `matches[]` entries** in the same rule, they're OR-ed.
- **Across `rules[]`**, the most specific match wins (Envoy Gateway
  implements Gateway API's precedence rules: exact > prefix; longer
  prefix beats shorter; explicit method/header/query matches beat
  those without).

This is **different from Phase 1**, where routes were strict top-to-
bottom first-match. Gateway API tries to be order-independent. In
practice when two rules tie on specificity, EG keeps rule order, but
you should write rules whose specificity does the disambiguation.

## Filters available on plain HTTPRoute

| Filter type             | What it does                                                |
|-------------------------|-------------------------------------------------------------|
| `RequestHeaderModifier` | `add` / `set` / `remove` request headers before upstream     |
| `ResponseHeaderModifier`| same, but on the response                                    |
| `RequestRedirect`       | Return 3xx; constructs Location from scheme/host/port/path  |
| `URLRewrite`            | Rewrite hostname / path before forwarding (`ReplacePrefixMatch` or `ReplaceFullPath`) |
| `RequestMirror`         | Send a copy to a second backend (fire-and-forget)            |
| `ExtensionRef`          | Point at an `HTTPRouteFilter` CR for advanced filters        |

Things plain HTTPRoute **doesn't** give you directly:

- **Fixed responses** (Phase 1's `direct_response`) — needs an
  `EnvoyPatchPolicy` or rolling your own backend.
- **Capture-group rewrites** (Phase 1's `regex_rewrite` with
  `$1`) — needs `HTTPRouteFilter` or `EnvoyPatchPolicy`.
- **Deny based on header presence** — use `SecurityPolicy` (example
  15) or `ext-authz` (example 16). Without a header you simply *don't
  match* the gated rule; the request falls through to whatever does.

## Walkthrough of `manifests/httproute.yaml`

Six rules; mapping to Phase 1 example 03's seven routes:

| #  | Phase 1                                           | Phase 2 (this file)                         |
|----|---------------------------------------------------|---------------------------------------------|
| 1  | `path /healthz` + `direct_response`                | **Not first-class.** See exercise 1.        |
| 2  | `prefix /api/v1/` + `prefix_rewrite "/"`           | Rule 1: `PathPrefix /api/v1` + `URLRewrite ReplacePrefixMatch /` |
| 3  | `prefix /legacy` + `redirect MOVED_PERMANENTLY`    | Rule 2: `PathPrefix /legacy` + `RequestRedirect statusCode: 301` |
| 4  | `prefix /admin` + `x-api-key: hunter2` → backend   | Rule 3: `PathPrefix /admin` + `headers[x-api-key]` + URLRewrite |
| 5  | `prefix /admin` → `direct_response 401`            | **No first-class deny.** Falls through to rule 6.  |
| 6  | `prefix /q` + `?debug=true` → backend + add x-debug | Rule 4: `PathPrefix /q` + `queryParams[debug]` + `RequestHeaderModifier set x-debug=on` |
| —  | (new for Phase 2)                                   | Rule 5: `RegularExpression /users/[0-9]+` → backend `/echo` |
| 7  | `prefix /` catch-all                                | Rule 6: `PathPrefix /` catch-all            |

The api.local virtual host from Phase 1 becomes a **separate
HTTPRoute** (`httproute-api-local.yaml`) attached to the same
Gateway, scoped via `spec.hostnames: ["api.local"]`.

## The "no first-class deny" pattern

Gateway API doesn't ship "return 401 when header missing". Instead:

- Write the **positive rule** (path + header match) with high
  specificity.
- Let the **catch-all rule** handle the unmatched case — typically
  forwarding to the backend, which may itself return 401, OR
- For real auth, layer a **SecurityPolicy** (example 15) on top —
  declarative deny on top of the matching rules.

If the difference between "no header → 401" and "no header → 404"
matters to you (it often does for API ergonomics), use SecurityPolicy
+ a SecurityPolicy `extAuth` provider, or an `HTTPRouteFilter`. This
example sticks with vanilla HTTPRoute to keep the comparison to
Phase 1 honest.

## Header / query param matchers — gotchas

```yaml
headers:
  - name: x-api-key
    type: Exact            # or RegularExpression
    value: hunter2
queryParams:
  - name: debug
    type: Exact
    value: "true"
```

- **Header names are case-insensitive** per HTTP spec; values are
  case-sensitive by default. Gateway API matches that.
- **Multiple `headers` / `queryParams` entries are AND-ed.** For OR,
  write a second `matches[]` entry.
- **Absence of a header** can't be matched at vanilla Gateway API
  level — you have to use `SecurityPolicy` or an EnvoyPatchPolicy.

## RequestRedirect — replacing path, hostname, port, scheme

```yaml
filters:
  - type: RequestRedirect
    requestRedirect:
      statusCode: 301              # default 302
      scheme: https                # optional
      hostname: example.com        # optional
      port: 443                    # optional
      path:
        type: ReplaceFullPath      # OR ReplacePrefixMatch
        replaceFullPath: /api/v1
```

A rule using `RequestRedirect` must have **no `backendRefs`** —
nothing's being forwarded. Trying to pair them is a config error and
the rule will be `Accepted=False`.

## URLRewrite — replacing path or hostname

```yaml
filters:
  - type: URLRewrite
    urlRewrite:
      hostname: backend.internal   # optional — rewrites :authority
      path:
        type: ReplacePrefixMatch
        replacePrefixMatch: /
```

Pairs with `backendRefs`. The two `path.type` values mirror the
Phase 1 `prefix_rewrite` (`ReplacePrefixMatch`) and a constrained
`regex_rewrite` (`ReplaceFullPath`). Capture-group substitutions
need `HTTPRouteFilter` or `EnvoyPatchPolicy`.

## RequestHeaderModifier — `add`, `set`, `remove`

```yaml
filters:
  - type: RequestHeaderModifier
    requestHeaderModifier:
      add:        - { name, value }   # append
      set:        - { name, value }   # overwrite
      remove:     [ x-internal-only ] # strip
```

- `add` is "append as another value" — useful for `Forwarded` chains.
- `set` is "replace any existing".
- `remove` strips before forwarding.

`ResponseHeaderModifier` has the same shape but applies to the
response from upstream.

## Verify

`make verify` does 9 hits (six rules from the main HTTPRoute, one
non-match, one through the api-local HTTPRoute, plus the catch-all).
For each request it prints the HTTP status and the backend's `path`
field — that's how we confirm the rewrite happened.

## Watching the generated route table

```bash
make admin   # port-forward Envoy admin :19000 in another terminal
curl -s localhost:19000/config_dump \
  | jq '.configs[]
        | select(."@type"|endswith("RoutesConfigDump"))
        | .dynamic_route_configs[].route_config.virtual_hosts'
```

Notice that the two HTTPRoutes show up as separate `virtual_hosts[]`
entries (different domain sets). Inside each, every rule becomes one
`routes[]` entry. The filter chain you wrote in Gateway API
materializes as Envoy `prefix_rewrite` / `redirect` /
`request_headers_to_add` etc. — the same shapes you wrote by hand in
Phase 1.

## Common failure modes

| Symptom                                            | Likely cause                                                       |
|----------------------------------------------------|---------------------------------------------------------------------|
| `RequestRedirect` + `backendRefs` → `Accepted=False` | Can't pair them. Pick one.                                          |
| `URLRewrite ReplacePrefixMatch` produces unexpected path | `replacePrefixMatch` is *literal* — `/api/v1` + `/api/v1/foo` becomes `/foo`, not `//foo`. Always check with `make verify`. |
| Regex match doesn't fire                           | Must match the *whole* path. `/users/[0-9]+` matches `/users/42` but not `/users/42/profile`. |
| `headers[]` match silently fails                   | Headers are case-sensitive on `value:`. `Exact: True` ≠ `Exact: true`. |
| Two rules both could match; wrong one wins         | Gateway API picks most-specific. Add specificity (longer path, more headers) to the rule you want. |

## Exercises

1. **Fixed response.** Without `EnvoyPatchPolicy` (which we cover in
   example 18), how would you implement `GET /healthz → 200 ok`? Try
   a tiny `Backend` resource pointing at an external "always 200"
   service, or a static-file pod.

2. **Capture-group rewrite.** Phase 1 example 03 exercise 1 used
   `regex_rewrite: "^/users/([0-9]+)$" → "/echo?user_id=\\1"`. Plain
   HTTPRoute can't do this; write an `HTTPRouteFilter` CR that does
   (we'll cover the CR in example 20 — for now, sketch the shape).

3. **Multiple HTTPRoutes on the same Gateway.** Add a third HTTPRoute
   in this namespace with `parentRefs: [{name: routing}]` and
   `hostnames: ["other.local"]`. Verify with
   `curl -H "Host: other.local"`. How does EG merge the routes?

4. **Cross-namespace attachment.** Move `httproute-api-local.yaml`
   to a different namespace. Without a `ReferenceGrant`, what does
   the status condition say? (Example 08 covers
   `ReferenceGrant` properly.)

5. **Method matching.** Add a rule that only matches `POST /echo` and
   redirects all other methods to `/`. Hint: `matches[].method`.

## Cleanup

```bash
make down
```

## What's next

- `04-gatewayclass-and-envoyproxy` — customize the *data plane* via
  the `EnvoyProxy` CR (replicas, resources, service type, log level).
