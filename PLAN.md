# Tutorial repo plan: Envoy Proxy → Envoy Gateway

A progression of self-contained, runnable examples that teach customers Envoy
from first principles, then layer Envoy Gateway on top, and always show how
Gateway API + Envoy Gateway CRDs translate into the underlying Envoy config.

## Audience and goals

- **Audience:** platform/SRE engineers at Giant Swarm customers who already
  know Kubernetes but have not necessarily touched Envoy directly.
- **Primary goal:** mental model of Envoy's config tree (listener → filter
  chain → HCM → route → cluster → endpoint), then the ability to read a
  generated Envoy config dump and trace it back to the Gateway/HTTPRoute/etc.
  that produced it.
- **Secondary goal:** a reference customers can copy from when debugging or
  building new Envoy Gateway use cases.

## Decisions

- **Walkthrough depth:** every example ships a tutorial-style `README.md`:
  what we are building, why each config block exists, the request flow, the
  commands to run, expected output, and 1–2 small exercises.
- **Versions:** pin Envoy and Envoy Gateway versions per example
  (image tags + chart versions in-file). All examples use the same pin at a
  given time; bumping is a single PR across the repo. Initial pins:
  - Envoy: latest stable at scaffolding time (target `envoyproxy/envoy:v1.34.x`).
  - Envoy Gateway: `v1.4.x` (first release with `XListenerSet` support).
- **Tooling:** every example has a `Makefile` with `up`, `verify`, `down`.
  Phase 1 uses `docker compose`. Phase 2 uses `kind` (bootstrapped once,
  reused across examples). No Tilt/Skaffold — keep the toolchain minimal.
- **Reusable app:** a single tiny Python helloworld lives in `apps/helloworld/`
  and is used across every example. Endpoints: `/`, `/headers`, `/slow`,
  `/fail`, `/echo`. Single `Dockerfile`, optional `image:` override per example.

## Repository layout

```
envoy-gateway-examples/
├── README.md                        # top-level map + how to navigate
├── PLAN.md                          # this file
├── apps/
│   └── helloworld/                  # shared Python app + Dockerfile
├── 01-envoy-proxy/                  # Phase 1: Envoy standalone in Docker
│   ├── README.md
│   └── NN-name/
│       ├── README.md                # tutorial walkthrough
│       ├── docker-compose.yml
│       ├── envoy.yaml               # heavily commented
│       ├── Makefile                 # up / verify / down
│       └── verify.sh                # curl/hey commands referenced by README
├── 02-envoy-gateway/                # Phase 2: Envoy Gateway on kind
│   ├── README.md
│   ├── 00-kind-bootstrap/           # shared cluster bootstrap; other examples depend on it
│   └── NN-name/
│       ├── README.md
│       ├── manifests/               # GatewayClass, Gateway, *Route, *Policy CRs
│       ├── Makefile                 # apply / verify / dump-envoy / clean
│       └── envoy-config.expected.yaml  # snapshot of egctl output for the mapping section
└── 03-debugging/                    # Phase 3: cheat sheets + reproductions
```

### Per-example README template

Every example's README follows the same shape so customers know where to look:

1. **What this shows** — one paragraph.
2. **Prerequisites** — versions, prior examples it builds on.
3. **Run it** — `make up`, expected output.
4. **Walkthrough** — annotated tour of the config(s).
5. **Verify** — `make verify` plus what the curl/hey output means.
6. **For Phase 2 examples: Envoy config mapping** — `make dump-envoy`, then
   the diff vs. the equivalent Phase 1 example.
7. **Exercises** — 1–2 small modifications the reader can try.
8. **Cleanup** — `make down`.

## Phase 1 — Envoy proxy standalone (`01-envoy-proxy/`)

Goal: by the end, the reader can read any Envoy YAML and trace a request
through it.

| #  | Example                  | What it teaches |
|----|--------------------------|----------------|
| 01 | `helloworld-static`      | One listener, one route, one cluster. Full tour of the YAML. |
| 02 | `config-anatomy`         | Same example, with `/config_dump`, `/clusters`, `/listeners`, `/stats` admin endpoints. |
| 03 | `routing-basics`         | Path / header / query-param matching, prefix rewrite, redirects. |
| 04 | `load-balancing`         | Two helloworld replicas → `round_robin`, `least_request`, `ring_hash`. |
| 05 | `health-checks`          | Active health checks + outlier detection. Kill a backend, watch traffic drain. |
| 06 | `timeouts-retries`       | `/slow` endpoint, per-route timeouts, retry policy. |
| 07 | `circuit-breakers`       | Max connections / pending / requests under load. |
| 08 | `fault-injection`        | HTTP fault filter: delay + abort. |
| 09 | `tls-termination`        | Self-signed certs, downstream TLS, SNI. Includes a passthrough variant. |
| 10 | `rate-limiting-local`    | `local_ratelimit` filter (no external service). |
| 11 | `rate-limiting-global`   | Envoy ratelimit service + Redis via `docker compose`. |
| 12 | `jwt-authn`              | `jwt_authn` filter with a static JWKS. |
| 13 | `ext-authz`              | Tiny Python ext-authz gRPC server. |
| 14 | `lua-filter`             | Per-request mutation via the Lua filter. |
| 15 | `wasm-filter`            | Minimal Wasm filter (Rust or Go) attached via `envoy.filters.http.wasm`. |
| 16 | `cors-and-headers`       | CORS filter + request/response header manipulation. |
| 17 | `access-logging`         | Stdout, file, and JSON access log formats. |
| 18 | `tracing-otlp`           | OTLP → Jaeger via `docker compose`. |
| 19 | `grpc-and-grpc-web`      | gRPC routing and the grpc-web bridge filter. Small `.proto`. |
| 20 | `websocket`              | Upgrade handling against a tiny ws echo backend. |
| 21 | `traffic-shadowing`      | Mirror to a second helloworld and diff responses. |

Cross-cutting note: the README for each example should explicitly call out
which Envoy resource type (`listeners`, `clusters`, `endpoints`, `routes`,
`secrets`) is the focus, so the Phase 2 mappings later have something to
point at.

## Phase 2 — Envoy Gateway on kind (`02-envoy-gateway/`)

Goal: by the end, the reader can express each Phase 1 example as Gateway API
+ Envoy Gateway CRs and can read the generated Envoy config to verify.

| #  | Example                                       | What it teaches |
|----|-----------------------------------------------|----------------|
| 00 | `kind-bootstrap`                              | `make kind-up`: kind cluster, Gateway API CRDs, Envoy Gateway install, helloworld deployment. Reused by every later example. |
| 01 | `helloworld-gateway`                          | `GatewayClass` + `Gateway` + `HTTPRoute`. Side-by-side with Phase 1 `01`. |
| 02 | `egctl-and-config-dump`                       | Reading the generated Envoy config; `egctl` tour; how xDS converges. |
| 03 | `httproute-matching-and-filters`              | Path/header/query matching + filters (URL rewrite, request mirror, redirect, header modifiers). |
| 04 | `gatewayclass-and-envoyproxy`                 | `EnvoyProxy` CR — customizing the data plane (replicas, resources, logging). |
| 05 | `tls-termination`                             | TLS at the Gateway. Cert-manager optional sidebar. |
| 06 | `grpcroute`                                   | Mirrors Phase 1 `19`. |
| 07 | `tcproute-udproute-tlsroute`                  | The non-HTTP route kinds. |
| 08 | `referencegrant`                              | Cross-namespace backend references. |
| 09 | `backend-resource`                            | The `Backend` CRD: routing to non-K8s services (FQDN, static IP). |
| 10 | `backendtlspolicy`                            | mTLS to upstream. |
| 11 | `clienttrafficpolicy`                         | Downstream tuning: connection limits, proxy protocol, HTTP/3, client cert auth. |
| 12 | `backendtrafficpolicy`                        | Retries, timeouts, circuit breakers, active health checks, load balancing — maps to Phase 1 `04`–`07`. |
| 13 | `securitypolicy-jwt`                          | JWT validation via `SecurityPolicy`. |
| 14 | `securitypolicy-oidc`                         | OIDC login flow with Dex or Keycloak in-cluster. |
| 15 | `securitypolicy-basicauth-cors-ipallow`       | Smaller `SecurityPolicy` features grouped: basic auth, CORS, IP allow/deny. |
| 16 | `securitypolicy-extauth`                      | External authz, mirrors Phase 1 `13`. |
| 17 | `envoyextensionpolicy-wasm-lua`               | EG-supported way to attach Wasm/Lua extensions. |
| 18 | `envoypatchpolicy`                            | Escape hatch: raw xDS patch when no CRD covers the use case. |
| 19 | `rate-limiting`                               | EG's global ratelimit feature; mirrors Phase 1 `11`. |
| 20 | `httproutefilter`                             | The `HTTPRouteFilter` CR for richer filter chains attached to an `HTTPRoute`. |
| 21 | `observability`                               | Access logs, metrics, OTLP traces wired via `EnvoyProxy` + `Telemetry`. |
| 22 | `listenersets`                                | **Headline new feature.** Base `Gateway` + multiple `XListenerSet`s contributing additional listeners (per-team / per-tenant). Show the merged listener set in the generated Envoy config. Cover the use case (sharing a Gateway across teams without rewriting the parent), the RBAC story, and the failure modes. |

Every Phase 2 example includes a **Mapping section** in its README:

- `egctl config envoy-proxy all -n envoy-gateway-system` (or the appropriate
  command) is captured into `envoy-config.expected.yaml`.
- The README points at the listener / route / cluster the CRs produced and
  links to the equivalent Phase 1 example for comparison.

## Phase 3 — Debugging companion (`03-debugging/`)

Short, recipe-driven. Not a tutorial; a reference.

- `egctl` cheat sheet (config dump, stats, status).
- Reading `/config_dump`, `/clusters`, `/stats`, `/listeners`, `/ready`.
- Common failure modes with reproductions:
  - Route not matching (precedence and ordering).
  - `503 NR / UH / UF / UC` flags decoded.
  - TLS handshake errors (downstream and upstream).
  - xDS not converging — what Gateway/HTTPRoute `status` conditions to read.
- A small "if X then look at Y" decision tree.

## Build order

1. Commit this plan. ← we are here
2. Scaffold `apps/helloworld/` (one shared app).
3. Build Phase 1 example `01-helloworld-static` end-to-end as the reference
   shape; pause for review of format and depth.
4. Fill out Phase 1 in order.
5. Build `02-envoy-gateway/00-kind-bootstrap` as the shared cluster setup.
6. Build Phase 2 example `01-helloworld-gateway` end-to-end including the
   Envoy mapping section; pause for review.
7. Fill out Phase 2 in order. `22-listenersets` is the headline closer.
8. Write Phase 3.

## Open items to revisit

- Wasm filter language (Rust vs. Go vs. AssemblyScript) — pick when we get
  to Phase 1 `15`.
- OIDC provider in Phase 2 `14` — Dex is lighter, Keycloak is more realistic
  for customer scenarios.
- Whether to also publish a rendered/static site (GitHub Pages with mkdocs)
  later, or keep everything as repo Markdown.
