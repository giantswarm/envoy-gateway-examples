# Phase 2 — Envoy Gateway on kind

Same backends, same questions as Phase 1 — but now Envoy is configured
via **Gateway API** + **Envoy Gateway CRDs** instead of hand-written
`envoy.yaml`. Every example **dumps the generated Envoy config** and
diffs it against the equivalent Phase 1 example so the translation is
explicit.

All examples share a single `kind` cluster bootstrapped by
[`00-kind-bootstrap`](./00-kind-bootstrap/). Start there.

## Workflow

```bash
# One-time, ~3 minutes
cd 00-kind-bootstrap
make up

# Per example
cd ../NN-name
make up        # kubectl apply this example's manifests
make verify    # exercise + show the generated Envoy config
make down      # kubectl delete only this example's manifests
```

The cluster stays up across examples. Tear it down only when you're
done with Phase 2: `cd 00-kind-bootstrap && make down`.

## Examples

| #  | Example                                              | Focus |
|----|------------------------------------------------------|-------|
| 00 | [`00-kind-bootstrap`](./00-kind-bootstrap/)          | kind cluster, Gateway API CRDs (experimental), Envoy Gateway helm install, shared helloworld. |
| 01 | [`01-helloworld-gateway`](./01-helloworld-gateway/)  | `GatewayClass` + `Gateway` + `HTTPRoute`. Generated `config_dump` snapshot + Phase 1 ↔ Phase 2 mapping table. |
| 02 | [`02-egctl-and-config-dump`](./02-egctl-and-config-dump/) | Seven `/config_dump` sections, EG resource-naming conventions, xDS convergence via `version_info`, single-request trace through the live config. |
| 03 | [`03-httproute-matching-and-filters`](./03-httproute-matching-and-filters/) | Path (Prefix/Exact/Regex), header + query + method matching, URLRewrite, RequestRedirect, RequestHeaderModifier, hostname-scoped route, rule ordering and specificity. |
| 04 | [`04-gatewayclass-and-envoyproxy`](./04-gatewayclass-and-envoyproxy/) | `EnvoyProxy` CR via Gateway-level `infrastructure.parametersRef`: replicas, image pin, resources, debug logging. Two-tier merge with GatewayClass default. |
| 05 | [`05-tls-termination`](./05-tls-termination/)        | Two HTTPS listeners on one Gateway, distinguished by SNI; `kubernetes.io/tls` Secrets + EG's SDS; cert-manager equivalent in README. |
| 06 | [`06-grpcroute`](./06-grpcroute/)                    | `GRPCRoute` with 4 rules (service-level, method-level, catch-all, reflection). `moul/grpcbin` backend. HTTP/2 enabled automatically via `Service.appProtocol`. |
| 07 | [`07-tcproute-udproute-tlsroute`](./07-tcproute-udproute-tlsroute/) | Three L4 route kinds on one Gateway: TCPRoute → istio tcp-echo, UDPRoute → CoreDNS, TLSRoute (passthrough) → nginx with its own cert. |
| 08 | [`08-referencegrant`](./08-referencegrant/)          | Cross-namespace cert + backendRef in one Gateway. Live "delete RG → ResolvedRefs flips → recover" demo. |
| 09 | [`09-backend-resource`](./09-backend-resource/)      | EG's `Backend` CRD — route to FQDN (external or in-cluster), static IP, or Unix socket. Produces STRICT_DNS / STATIC clusters instead of EDS. |
| 10 | [`10-backendtlspolicy`](./10-backendtlspolicy/)      | Envoy → backend TLS: `BackendTLSPolicy` with CA in a ConfigMap + SAN-matched hostname validation. Negative test by deleting the policy. |
| 11 | [`11-clienttrafficpolicy`](./11-clienttrafficpolicy/) | EG `ClientTrafficPolicy` — three observable knobs (XFF trust hops, HTTP/1 header case, path merge-slashes); shows where each lands in the generated HCM config. |
| 12 | [`12-backendtrafficpolicy`](./12-backendtrafficpolicy/) | EG `BackendTrafficPolicy` — five features at once (retry, timeout, LB, active HC, outlier detection). Behavioral tests for retry + timeout, config_dump proof for the rest. |
| 13 | [`13-securitypolicy-jwt`](./13-securitypolicy-jwt/)  | `SecurityPolicy.jwt` with `localJWKS.inline`, claim-to-header extraction, and 5 verify scenarios (missing/valid/expired/wrong-aud/wrong-iss). Mirrors Phase 1 ex 12. |
| 14 | `14-securitypolicy-oidc` *(planned)*                  | OIDC login flow with Dex or Keycloak. |
| 15 | `15-securitypolicy-basicauth-cors-ipallow` *(planned)*| Smaller `SecurityPolicy` features grouped. |
| 16 | `16-securitypolicy-extauth` *(planned)*               | External authz; mirrors Phase 1 `13`. |
| 17 | `17-envoyextensionpolicy-wasm-lua` *(planned)*        | EG-supported Wasm/Lua extension attachment. |
| 18 | `18-envoypatchpolicy` *(planned)*                     | Escape hatch: raw xDS patch when no CRD covers it. |
| 19 | `19-rate-limiting` *(planned)*                        | EG's global ratelimit; mirrors Phase 1 `11`. |
| 20 | `20-httproutefilter` *(planned)*                      | The `HTTPRouteFilter` CR for richer filter chains. |
| 21 | `21-observability` *(planned)*                        | Access logs, metrics, OTLP traces via `EnvoyProxy` + `Telemetry`. |
| 22 | `22-listenersets` *(planned)*                         | **Headline new feature.** Base `Gateway` + multiple `XListenerSet`s, merged listener config in `egctl`. |

## The mapping section

Every example from 01 onward has a **Mapping** section that:

1. Runs `egctl config envoy-proxy all -n envoy-gateway-system <pod>`.
2. Saves the result as `envoy-config.expected.yaml` in the example dir.
3. Points at the listener / route / cluster the CR produced and links
   back to the equivalent Phase 1 example for comparison.

This is the point of Phase 2: make the translation visible so when
something breaks in production, you know which CR field produced which
piece of Envoy config.

## Prerequisites for all of Phase 2

- A running cluster created by `00-kind-bootstrap`.
- `kubectl`, `helm`, `kind`, `docker`. (See `00-kind-bootstrap`'s
  README for version notes.)
- Optional but handy: `egctl` (`go install
  github.com/envoyproxy/gateway/cmd/egctl@latest`) for the
  `config envoy-proxy all` walkthroughs in examples 02 and beyond.
