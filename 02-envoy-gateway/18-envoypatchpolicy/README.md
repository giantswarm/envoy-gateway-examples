# 18 — EnvoyPatchPolicy: raw xDS escape hatch

When no CRD covers your use case, **`EnvoyPatchPolicy`** lets you
apply JSON-Patch operations directly to the Envoy resources EG
generates for a Gateway. It's the "last resort" CR — powerful but
dangerous, because you're writing raw Envoy config that wasn't
designed for human authoring.

This example shows two patches in one policy:

1. **Listener-level**: bump `per_connection_buffer_limit_bytes` to
   1 MiB.
2. **RouteConfig-level**: append a `x-patched-by: envoy-patch-policy`
   header to every response.

Both are observable — the buffer via `/config_dump`, the header via
`curl -i`.

By the end you should be able to answer:

- When SHOULD you use EnvoyPatchPolicy? When should you NOT?
- What's the targeting model — what does it attach to, and what
  does that mean for the patch scope?
- How does the `name:` field find the right Envoy resource?
- What JSON-Patch operations are supported, and how does `path:`
  work?
- What happens when a patch is malformed?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–16. (Example 17 / Wasm-Lua is skipped in this
  tutorial.)
- EG's `extensionApis.enableEnvoyPatchPolicy: true` flag — fresh
  bootstraps have it on; the Makefile's `ensure-patch-api` target
  enables it via `helm upgrade --reuse-values` if needed.

## Run it

```bash
make up           # self-heals the feature flag, applies Gateway + HTTPRoute + EPP
make verify       # 5-section walkthrough: header check + config_dump proof
make admin
make down
```

## When to reach for EnvoyPatchPolicy

✅ Use it when:

- You need a knob EG hasn't surfaced as a CRD (yet, or ever).
- You want to attach an Envoy filter no CRD wraps.
- You need to patch the bootstrap config (e.g. add a static
  cluster for OTLP traces before EG-managed dynamic resources).

❌ Don't use it when:

- A CRD already does it. EnvoyPatchPolicy bypasses EG's
  validation, status reporting, and stability guarantees. If
  you could've used `BackendTrafficPolicy` for the retry knob,
  use that instead.
- The patch needs to apply uniformly to many Gateways. EPP
  attaches to ONE Gateway at a time (note `targetRef:` is
  singular). For cluster-wide knobs, use `EnvoyProxy` (example
  04).
- The shape changes between EG versions. Listener / route /
  cluster proto fields are stable, but EG's INTERNAL naming and
  organization is not part of the API contract. Upgrade-time pain
  is real.

## Targeting + naming

```yaml
spec:
  targetRef:                         # singular — exactly ONE Gateway
    group: gateway.networking.k8s.io
    kind: Gateway
    name: patched
  priority: 0                        # lower = applied first; default 0
  type: JSONPatch                    # or Merge
  jsonPatches:
    - type: "type.googleapis.com/envoy.config.listener.v3.Listener"
      name: demo/patched/http
      operation:
        op: replace
        path: /per_connection_buffer_limit_bytes
        value: 1048576
```

The `name:` field uses **EG's internal naming convention** for the
generated Envoy resource:

| Envoy resource             | `name:` pattern                                  |
|----------------------------|--------------------------------------------------|
| Listener                   | `<gw-ns>/<gw-name>/<listener-name>`              |
| RouteConfiguration         | `<gw-ns>/<gw-name>/<listener-name>`              |
| Cluster (Service-backed)   | `<svc-ns>/<svc-name>:<port>`                     |
| Cluster (Backend CR)       | `<be-ns>/<be-name>`                              |
| ClusterLoadAssignment      | matches the Cluster name                         |
| Secret                     | `<gw-ns>/<gw-name>/<listener-name>/<secret-name>`|

The fastest way to figure out a name is to look at
`/config_dump`. Spin up `make admin` and inspect:

```bash
curl -s http://localhost:19000/config_dump \
  | jq -r '.configs[].dynamic_listeners[]?.name // empty'
```

## JSON Patch (RFC 6902) operations

```yaml
operation:
  op: <add|remove|replace|move|copy|test>
  path: <JSON Pointer, RFC 6901>
  value: <JSON>             # for add/replace/test
  from: <JSON Pointer>      # for move/copy
```

A few `path:` patterns you'll use a lot:

- `/some_field` — top-level field replacement
- `/arr/0` — replace the FIRST element of an array
- `/arr/-` — append to the array (the JSON-Pointer "after-end" marker)
- `/arr/3/sub_field` — into a specific array element

The patches in this example:

```yaml
# Patch 1 — replace a top-level listener field
op: replace
path: /per_connection_buffer_limit_bytes
value: 1048576

# Patch 2 — append a header to the route_config's
# response_headers_to_add list
op: add
path: /response_headers_to_add/-
value:
  header:
    key: x-patched-by
    value: envoy-patch-policy
  append_action: APPEND_IF_EXISTS_OR_ADD
```

## What happens when a patch is malformed

| Error                                                  | Status seen                                                                  |
|---------------------------------------------------------|------------------------------------------------------------------------------|
| JSON Pointer references missing field                  | EPP condition `Programmed=False reason: JSONPatchParsingError`               |
| Patched resource fails Envoy's proto validation         | xDS push rejected; data plane keeps last-known-good config; Envoy logs the rejection (`make logs`) |
| `name:` doesn't match any EG-generated resource         | EPP condition `Programmed=False reason: ResourceNotFound`                    |
| Wrong proto `type:` (typo in URL)                       | EPP condition `Programmed=False reason: UnsupportedType`                     |
| Two EPPs make conflicting changes (same field)          | The HIGHER `priority` wins; the loser is silently overwritten                |

EG keeps applying patches in priority order until one fails; on
failure, the WHOLE patch policy is rolled back (the data plane
keeps its previous state). Watch for the `Programmed` condition.

## The pieces

```
manifests/
├── gateway.yaml            # Gateway 'patched'
├── httproute.yaml          # / -> helloworld
└── envoypatchpolicy.yaml   # two JSON patches
```

## Verify

`make verify` runs 5 sections:

1. Gateway Programmed + EPP `Programmed=True`.
2. Port-forward + GET / → see `x-patched-by: envoy-patch-policy`.
3. `/config_dump`: confirm
   `listener.per_connection_buffer_limit_bytes == 1048576`.
4. `/config_dump`: route_config's `response_headers_to_add[]`
   includes our header.
5. Mapping table for the EPP fields.

## Exercises

1. **Listener idle timeout.** Add a third JSON patch that sets the
   HCM's `stream_idle_timeout` to 30s. Verify in
   `/config_dump`. (The path is deeper: navigate to
   `filter_chains[0].filters[0].typed_config.stream_idle_timeout`.)

2. **Wrong name.** Change the `name:` of patch 1 to
   `demo/patched/typo`. Re-apply and watch the EPP go to
   `Programmed=False`. Read the condition's `message:`.

3. **`type: Merge` variant.** Re-express the patches using the
   Merge type instead of JSONPatch. (Merge is whole-resource
   overlay; less surgical, but easier to read.)

4. **Two EPPs, conflicting.** Create a second EPP also targeting
   `patched`, with a different value for
   `per_connection_buffer_limit_bytes` and `priority: 10`. Which
   value wins? Confirm with `/config_dump`.

5. **Patch a cluster.** Use type
   `type.googleapis.com/envoy.config.cluster.v3.Cluster` and
   `name: demo/helloworld:8080` to set
   `dns_lookup_family: V4_ONLY`. (This only matters for FQDN/STRICT_DNS
   clusters; for EDS this would just be there as metadata.)

## Cleanup

```bash
make down
```

## What's next

- [`19-rate-limiting`](../19-rate-limiting/) — EG's global rate
  limiting; mirrors Phase 1 ex 11.
