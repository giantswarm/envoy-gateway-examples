# 07 — TCPRoute, UDPRoute, TLSRoute

The non-HTTP route kinds. Same `Gateway` shape as everything else,
but the listeners speak **TCP**, **UDP**, or **TLS-passthrough**
instead of HTTP, and the route resources are L4 — they forward bytes
or packets, they don't inspect content.

Shape: **one Gateway with three listeners**, each backed by its own
purpose-built pod:

- `tcp-echo` (istio's reference TCP echo) → reached via `TCPRoute`.
- `coredns` serving `example.test` → reached via `UDPRoute`.
- `nginx` with its own self-signed cert → reached via
  `TLSRoute` (Passthrough).

By the end of this example you should be able to answer:

- When do you use `TCPRoute` / `UDPRoute` / `TLSRoute` vs
  `HTTPRoute` / `GRPCRoute`?
- What does each route kind let you match on? (Spoiler: not much —
  L4 forwarding is intentionally dumb.)
- How does `tls.mode: Passthrough` differ from `Terminate`?
- What Envoy filter chain shape does each route kind produce?
- Why does `kubectl port-forward` need a special workaround for
  the UDP test?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–06.
- `openssl`, `nc` (netcat) on your `$PATH`.

## Run it

```bash
make up           # gen-certs.sh, then apply 8 manifests in dependency order
make verify       # 6 sections: status, TCP, TLS, UDP (in-cluster), config dump, mapping
make admin        # in another terminal — Envoy admin :19000
make down
```

`make up` is split into phases so the Namespace settles before the
Gateway and routes are applied (same pattern as example 06 — see
`Makefile`).

## What each route kind gives you

```yaml
# TCPRoute — pure L4 forwarding. NO matches[].
spec:
  parentRefs: [{ name: l4, sectionName: tcp }]
  rules:
    - backendRefs: [{ name: tcp-echo, port: 9000 }]

# UDPRoute — same shape, but for UDP. NO matches[] either.
spec:
  parentRefs: [{ name: l4, sectionName: udp }]
  rules:
    - backendRefs: [{ name: coredns, port: 5353 }]

# TLSRoute — has `hostnames:` (SNI) but otherwise L4.
# Only attaches to listeners with `tls.mode: Passthrough`.
spec:
  parentRefs: [{ name: l4, sectionName: tls }]
  hostnames: [ tls.local ]
  rules:
    - backendRefs: [{ name: tls-backend, port: 8443 }]
```

What you CAN'T do at L4:

- No path / header / query / method matching (no L7 visibility).
- No request rewrites, no header injection, no redirects.
- No retry / circuit breaker (those work, but at the *connection*
  level, not request — covered in example 12 via
  `BackendTrafficPolicy`).
- No fault injection of HTTP responses (would have to truncate the
  TCP stream).

What you CAN do — `BackendRef` weighting still works:

```yaml
rules:
  - backendRefs:
      - { name: tcp-echo-blue,  port: 9000, weight: 90 }
      - { name: tcp-echo-green, port: 9000, weight: 10 }
```

EG translates that into Envoy's weighted-cluster TCP proxy. Useful
for canarying L4 services (think Redis, Postgres proxies, mTLS
sidecars).

## TLSRoute vs TLS termination (example 05)

| Aspect                | Example 05 (`Terminate`)                                | This example (`Passthrough`)                                          |
|-----------------------|----------------------------------------------------------|----------------------------------------------------------------------|
| Envoy sees plaintext? | Yes (after handshake)                                    | No — encrypted bytes flow through Envoy                              |
| Cert lives at         | Gateway (in `tls.certificateRefs[]` Secret)              | Backend pod (in our case, mounted into nginx)                        |
| Attaches              | `HTTPRoute` / `GRPCRoute`                                | `TLSRoute` only                                                       |
| Use when              | You own the backend and want a single cert pool          | You can't touch the backend (legacy, externally-managed cert), or compliance demands end-to-end TLS |
| Drawback              | One more thing to rotate                                 | No L7 features, no observability of paths/methods                    |

Envoy still **peeks at the SNI** with `tls_inspector` so it can route
to the right backend, but it never decrypts the handshake itself.

## How EG translates each into Envoy config

```
TCPRoute (port 9001, TCP)
  Envoy listener :9001 (TCP)
  └── filter_chain
      └── filters: tcp_proxy { cluster: <backend> }

UDPRoute (port 5353, UDP)
  Envoy listener :5353 (UDP)
  └── udp_listener_config
      └── filters: udp_proxy { cluster: <backend> }

TLSRoute (port 8443, TLS-passthrough)
  Envoy listener :8443 (TCP)
  ├── listener_filters: tls_inspector              <- peeks at ClientHello
  └── filter_chain
      filter_chain_match { server_names: [tls.local] }
      filters: tcp_proxy { cluster: <backend> }    <- still TCP, no DownstreamTLS

HTTPRoute (port 80, HTTP)
  Envoy listener :80 (TCP)
  └── filter_chain
      └── filters: http_connection_manager
           +-- route table -> cluster (L7-aware)
```

`make verify` dumps each listener's first network filter so you can
prove this. The TCP one shows `envoy.filters.network.tcp_proxy`,
the HTTPS-passthrough one shows the same TCP filter but with a
`server_names` matcher.

## The UDP testing wrinkle

`kubectl port-forward` is **TCP-only**. To test the UDPRoute we
spawn an ephemeral pod with `dig` inside the cluster, target the
data-plane Service's UDP port, and verify the answer. `verify.sh`
does this with `kubectl run --rm` + an alpine image that installs
`bind-tools` on the fly.

Other workarounds:

- `kubectl debug` an existing pod and dig from there.
- For production, use a `NodePort` Service so the kind node exposes
  UDP on a host port; then `dig @<node-ip> -p <port>` from your
  laptop works.

## The pieces

```
manifests/
├── 00-namespace.yaml     # l4-demo
├── tcp-echo.yaml         # istio/tcp-echo-server:1.3 + Service :9000 (TCP)
├── coredns.yaml          # coredns/coredns:1.11.3 + Corefile + Service :5353 (UDP)
├── tls-backend.yaml      # nginx:1.27-alpine + nginx.conf + Service :8443 (TCP)
├── gateway.yaml          # Gateway 'l4' with 3 listeners
├── tcproute.yaml         # v1alpha2 — TCPRoute -> tcp-echo
├── udproute.yaml         # v1alpha2 — UDPRoute -> coredns
└── tlsroute.yaml         # v1alpha2 — TLSRoute -> tls-backend (SNI tls.local)
```

`TCPRoute`, `UDPRoute`, `TLSRoute` are all still in
`gateway.networking.k8s.io/v1alpha2` (experimental channel). Our
[`00-kind-bootstrap`](../00-kind-bootstrap/) installs the
experimental-channel CRDs precisely for this.

`gen-certs.sh` produces a self-signed cert for `tls.local` (no CA
chain — the client will need `--insecure` / `-k`). It's mounted into
the nginx pod via a `kubernetes.io/tls` Secret.

## Common failure modes

| Symptom                                                                                | Cause                                                                                                                  |
|-----------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| `TCPRoute` `Accepted=False reason: NotAllowedByListeners`                              | The listener's `allowedRoutes.kinds:` doesn't include `TCPRoute`. Add it explicitly.                                  |
| `TLSRoute` `Accepted=False reason: UnsupportedValue`                                   | Attached to a listener whose `tls.mode` is `Terminate` (not `Passthrough`), or to an HTTP/HTTPS listener.             |
| Listener condition `Programmed=False reason: TLSConfigurationInvalid`                  | TLS-passthrough listener has `tls.certificateRefs[]` set. Remove it — passthrough listeners never hold certs.         |
| `kubectl port-forward` for the UDP port silently does nothing                          | port-forward is TCP-only. Use the in-cluster `dig` test instead (see `make verify` section 4 and the README sidebar). |
| `dig` from the ephemeral pod hangs                                                     | CoreDNS Corefile zone doesn't match the query name. Our zone is `example.test:5353` — try `demo.example.test`.        |
| TLS-passthrough `curl` returns the wrong cert                                          | Two listeners overlap on port + protocol. Make sure only one TLS-passthrough listener matches your SNI.                |

## Exercises

1. **Weighted TCP canary.** Add a second `tcp-echo` Deployment that
   echoes with a `goodbye ` prefix, expose it as `tcp-echo-v2`, and
   split the TCPRoute 70/30. `for i in $(seq 1 20); do echo $i | nc localhost 19001 ; done`
   — verify the ratio.

2. **Strict SNI gating.** Add a second TLSRoute (`hostnames:
   [other.local]`) attached to the same TLS-passthrough listener.
   Generate a second backend cert. Verify that an SNI of
   `other.local` reaches that backend; `tls.local` keeps reaching
   the first.

3. **UDP load balancing.** Bump `coredns` to 3 replicas and add an
   anti-affinity rule. UDPRoute "load balances" each packet
   independently (no connection state). Use
   `dig @... +tries=20 +retry=0` and look at the source pod via
   CoreDNS access logs — should be spread across all 3.

4. **L4 + observability.** L4 routes don't show `:path` in access
   logs. What CAN you log? Look at the EnvoyProxy CR's
   `telemetry.accessLog.format` field — what format strings work
   when there's no HTTP context?

5. **Migrate one to L7.** Replace the TLSRoute with an HTTPS
   listener (`mode: Terminate`) + Secret + HTTPRoute. What do you
   gain? What do you lose? When would you NOT want to do this?

## Cleanup

```bash
make down               # tear down everything (routes first, then backends, then ns)
make clean-certs        # rm -rf certs/
```

## What's next

- [`08-referencegrant`](../08-referencegrant/) — let routes in one
  namespace point at backends/secrets in another, safely.
