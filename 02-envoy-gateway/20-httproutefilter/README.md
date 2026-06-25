# 20 — HTTPRouteFilter: capture-group rewrites + direct responses

`HTTPRouteFilter` is EG's CRD that fills the gaps where vanilla
Gateway API's `HTTPRoute.filters[]` runs out of expressiveness.

| Capability                              | Vanilla HTTPRoute              | HTTPRouteFilter                              |
|------------------------------------------|--------------------------------|----------------------------------------------|
| Literal prefix rewrite                  | `URLRewrite.path.ReplacePrefixMatch` | (also; see below)                        |
| Full-path rewrite                       | `URLRewrite.path.ReplaceFullPath`     | (also)                                   |
| **Regex rewrite with capture groups**   | ❌ no                          | ✅ `urlRewrite.path.ReplaceRegexMatch`        |
| **Fixed/direct response (no backend)**  | ❌ no (best: redirect)         | ✅ `directResponse` (status + body)           |
| Credential injection (Basic / Bearer)   | ❌ no                          | ✅ `credentialInjection` (not covered here)   |

This example wires up two HTTPRouteFilter CRs:

1. **`users-rewrite`** — `^/users/([0-9]+)$` → `/echo?user_id=\1`.
   The backend sees the captured ID as a query param. Same shape as
   Phase 1 example 03's exercise that vanilla HTTPRoute couldn't do.
2. **`healthz-direct`** — `/healthz` returns 200 + `{"status":"ok",...}`
   directly from Envoy. No backend call.

By the end you should be able to answer:

- What gaps does HTTPRouteFilter fill?
- How does an HTTPRoute reference a HTTPRouteFilter?
- What's the regex syntax — what flavor does Envoy support?
- What's the difference between `body.type: Inline` and
  `body.type: ValueRef`?
- What's the Envoy artifact each filter generates?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–19.

## Run it

```bash
make up           # 2 filter CRs + Gateway + HTTPRoute (filters applied first)
make verify       # 7-section walkthrough
make admin
make down
```

## How HTTPRoute references HTTPRouteFilter

Same `ExtensionRef` mechanism Gateway API defines for ANY extension
filter:

```yaml
filters:
  - type: ExtensionRef
    extensionRef:
      group: gateway.envoyproxy.io
      kind:  HTTPRouteFilter
      name:  users-rewrite
```

The HTTPRouteFilter CR can be referenced by multiple HTTPRoutes if
the same transformation applies in several places. It must live in
the same namespace as the HTTPRoute that references it (no
`ReferenceGrant` for HTTPRouteFilter in v1alpha1).

## URL rewrite with capture groups

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: HTTPRouteFilter
spec:
  urlRewrite:
    path:
      type: ReplaceRegexMatch
      replaceRegexMatch:
        pattern: '^/users/([0-9]+)$'        # Go RE2 syntax
        substitution: '/echo?user_id=\1'    # \1 .. \9 backreferences
```

Notes:

- Regex flavor is **Go RE2** (`re2`). No lookbehind, no backreferences
  inside the pattern, but capture groups are fine.
- The pattern matches the FULL path (use anchors `^...$`).
- Substitution can contain `\1` through `\9`, the captured groups.
- This is conceptually identical to Envoy's `regex_rewrite` on a
  route (the same field Phase 1 example 03 used). The check via
  `/config_dump` in `make verify` confirms it lands there.

Combine with the standard HTTPRoute `RegularExpression` path match
for the strictest behavior — your route only fires when the regex
matches, and the rewrite uses the same regex semantics for capture.

## Direct response

```yaml
spec:
  directResponse:
    statusCode: 200
    contentType: application/json
    body:
      type: Inline
      inline: |
        {"status":"ok","served_by":"envoy-gateway"}
```

Or load the body from a ConfigMap (useful for long bodies — OpenAPI
specs, maintenance HTML, etc.):

```yaml
spec:
  directResponse:
    statusCode: 200
    contentType: application/json
    body:
      type: ValueRef
      valueRef:
        group: ""
        kind: ConfigMap
        name: openapi-spec
        # The ConfigMap must have a `response.body` key — or Envoy
        # uses whatever single key is present.
```

When a route uses `directResponse`, the rule's `backendRefs` are
unused (Envoy answers from the filter). You can omit `backendRefs`
entirely — `manifests/httproute.yaml` does for `/healthz`.

## The pieces

```
manifests/
├── filter-rewrite.yaml      # HTTPRouteFilter — ReplaceRegexMatch
├── filter-healthz.yaml      # HTTPRouteFilter — directResponse
├── gateway.yaml
└── httproute.yaml           # 3 rules: /users/N, /healthz, catch-all
```

`make up` applies the filter CRs FIRST, then the HTTPRoute that
references them. Reverse order leaves the route briefly in
`ResolvedRefs=False`.

## Verify

`make verify` walks through 7 sections:

1. CRs Accepted, HTTPRoute `ResolvedRefs=True` (both filters resolved).
2. Port-forward.
3. **Rewrite happy path**: `GET /users/42` → backend sees
   `/echo?user_id=42`.
4. **Rewrite scoped correctly**: `/users/abc` falls through to the
   catch-all (helloworld 404).
5. **Direct response**: `GET /healthz` → 200 with the inline JSON;
   helloworld logs show NO `/healthz` hit (proves no backend call).
6. **Catch-all** sanity.
7. `/config_dump`: routes with their respective actions
   (`regex_rewrite "..." -> "..."` vs `direct_response status=200`).

## Common failure modes

| Symptom                                                                       | Cause                                                                                                                  |
|--------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| HTTPRoute `ResolvedRefs=False reason: BackendNotFound`                         | Filter CR name typo in `extensionRef.name`, OR the filter is in another namespace (cross-ns not supported in v1alpha1).|
| Rewrite seems to do nothing                                                    | Pattern doesn't have `^...$` anchors — partial match still happens, but the path Envoy emits keeps the un-matched tail. Anchor both ends. |
| Direct response returns the helloworld 404 instead                             | Path match in the HTTPRoute didn't fire. Check `match.path.type` and value; OR the catch-all rule is listed BEFORE the directResponse rule (rule order can shadow). |
| HTTPRoute `ResolvedRefs=False reason: Invalid`                                 | The HTTPRouteFilter's spec failed validation (e.g. malformed regex). `kubectl describe httproutefilter` shows the parse error. |
| `\1` shows up in the upstream literally                                        | Substitution string was single-quoted in YAML AND wasn't escaped properly. Use plain `'...'` YAML quoting — the backslash is literal there. |
| ConfigMap-backed body returns empty                                            | Wrong key name in the ConfigMap. EG looks for `response.body` first; if absent, picks the single key. Multiple-keyed ConfigMaps without `response.body` are ambiguous. |

## Exercises

1. **Multi-capture rewrite.** Add a filter that turns
   `^/api/v(\d+)/users/(\d+)$` into
   `/echo?api=v\1&user_id=\2`. Verify both captures land.

2. **ConfigMap-backed body.** Move the `/healthz` body into a
   ConfigMap. Update the filter to `type: ValueRef`. Confirm
   `curl /healthz` returns the same JSON.

3. **Maintenance page.** Create a `503` directResponse filter
   that returns a JSON `{"error":"under maintenance"}` and apply
   it as the FIRST rule with `match.path.type: PathPrefix /`. Now
   every request returns 503. Remove the rule to "un-maintenance".

4. **Capture into a header.** Standard HTTPRoute can't read a
   regex capture into a header. With `regex_rewrite` we put it
   into the query string. Try expressing the same as a
   `RequestHeaderModifier.set` — does HTTPRouteFilter offer
   something? (Hint: there isn't a clean way without an
   EnvoyPatchPolicy, ex 18.)

5. **Reuse the filter across two HTTPRoutes.** Add a second
   HTTPRoute (different parent Gateway or same) and reference
   `users-rewrite` from it too. Confirm the regex applies to
   both routes.

## Cleanup

```bash
make down
```

## What's next

- [`21-observability`](../21-observability/) — access logs,
  metrics, OTLP traces wired up via `EnvoyProxy` + `Telemetry`.
