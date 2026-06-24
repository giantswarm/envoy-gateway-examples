# 05 — TLS termination at the Gateway

Phase 2's answer to [Phase 1 example 09](../../01-envoy-proxy/09-tls-termination/).
We terminate TLS at the Envoy data plane via Gateway API's native
`tls.certificateRefs` — no extra CRDs, no SecurityPolicy, no
cert-manager required (though we cover the cert-manager flow in a
sidebar).

Shape: **one Gateway, two HTTPS listeners on :443**, distinguished by
SNI (`hostname:` field). Each listener has its own Secret-backed
certificate. Envoy Gateway translates this into a single Envoy
listener with two `filter_chains`, gated by `filter_chain_match {
server_names: [...] }` — the same shape we hand-wrote in Phase 1.

By the end of this example you should be able to answer:

- How do you terminate TLS at a Gateway in Gateway API?
- What's the relationship between `Gateway.spec.listeners[].hostname`,
  SNI, and Envoy's `filter_chain_match.server_names`?
- How do `tls.mode: Terminate` and `Passthrough` differ?
- Where do certificates live, what kind of Secret holds them, and how
  does EG pick them up?
- What does the per-listener `status` mean? When does
  `ResolvedRefs=False` fire?
- How does cert-manager fit on top of this?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–04.
- `openssl` on your `$PATH`. (`brew install openssl` on macOS.)

## Run it

```bash
make up           # gen-certs.sh -> Secrets -> apply Gateway + HTTPRoutes
make verify       # 7-step walkthrough: TLS handshakes + Envoy mapping
make admin        # in another terminal — port-forward Envoy admin :19000
make down
```

`make up` runs `gen-certs.sh` automatically (idempotent — skips if
`certs/` already has a CA + both leaf certs). Output:

```
certs/
├── ca.crt          # the local CA — pass to curl --cacert
├── ca.key
├── hello.local.crt # leaf signed by the CA, SAN=DNS:hello.local
├── hello.local.key
├── api.local.crt   # leaf signed by the CA, SAN=DNS:api.local
└── api.local.key
```

`certs/` is in `.gitignore` — never commit private keys.

## The pieces

`gen-certs.sh` — produces the CA + two leaf certs idempotently with
`openssl`. Same shape as Phase 1 ex 09's helper.

`manifests/gateway.yaml` — one Gateway `secure` with two HTTPS
listeners on port 443. Each listener has its own `hostname:`
(populates `filter_chain_match.server_names` in Envoy) and
`tls.certificateRefs[]` pointing at the matching TLS Secret.

`manifests/httproute-hello.yaml` — HTTPRoute attached to the
`https-hello` listener via `parentRefs[].sectionName`. Belt-and-braces
`hostnames:` at the route level too.

`manifests/httproute-api.yaml` — same shape; routes `api.local`
requests. Adds a `RequestHeaderModifier` filter setting
`x-served-by: api-listener` so you can prove the listener selection
worked.

The Makefile materializes the certs into two `kubernetes.io/tls`
Secrets (`hello-tls`, `api-tls`) via `kubectl create secret tls
--dry-run=client -o yaml | kubectl apply -f -` — idempotent on
re-runs.

## How the Gateway API maps to Envoy filter chains

```
Gateway secure
├── listener https-hello (hostname: hello.local, port 443, HTTPS)
│   └── tls.certificateRefs: [Secret/hello-tls]
└── listener https-api   (hostname: api.local,   port 443, HTTPS)
    └── tls.certificateRefs: [Secret/api-tls]

==> Envoy listener on :443
    ├── listener_filters: tls_inspector   (auto-injected by EG)
    └── filter_chains:
        ├── filter_chain_match { server_names: [hello.local] }
        │   transport_socket DownstreamTlsContext { cert: hello-tls (SDS) }
        │   filters: HCM -> route_config(hello)  -> cluster(helloworld)
        └── filter_chain_match { server_names: [api.local] }
            transport_socket DownstreamTlsContext { cert: api-tls   (SDS) }
            filters: HCM -> route_config(api)    -> cluster(helloworld)
```

EG manages cert material via SDS (the Secret Discovery Service) so a
rotated Secret hot-swaps the cert inside Envoy without a config
reload.

## `tls.mode: Terminate` vs `Passthrough`

| Mode          | What Envoy does                                                       | When you'd use it                                      |
|---------------|------------------------------------------------------------------------|---------------------------------------------------------|
| `Terminate`   | Decrypts the TLS handshake using the cert in `certificateRefs[]`. The upstream connection is plaintext (unless you also add a [`BackendTLSPolicy`](../10-backendtlspolicy/), example 10). | The common case — TLS to the user, plaintext to your in-cluster service. |
| `Passthrough` | Envoy reads the SNI but does **not** terminate. The TCP stream is forwarded byte-for-byte to a backend that does its own TLS. **`certificateRefs:` must NOT be set.** Only `TLSRoute` (TCP-level, see example 07) can attach. | When you can't (or don't want to) put the cert at the edge — e.g. legacy backend, end-to-end TLS by policy. |

This example uses `Terminate` for both listeners. Exercise 5 walks
through swapping one to `Passthrough`.

## The TLS Secret format

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: hello-tls
  namespace: demo
type: kubernetes.io/tls           # ← required; EG rejects other types
data:
  tls.crt: <base64 cert chain>    # leaf cert + any intermediates
  tls.key: <base64 private key>
```

`kubectl create secret tls --cert=... --key=...` produces exactly
this shape. The Secret must be in the **same namespace as the
Gateway**, unless you create a [`ReferenceGrant`](../08-referencegrant/)
(example 08) — same cross-namespace rule as for `backendRefs`.

## Per-listener status — the fast path to "why isn't TLS working"

Unlike the top-level `Gateway` conditions, each listener has its own
status block. Check it when one listener works and another doesn't:

```bash
kubectl -n demo get gateway secure -o yaml | yq '.status.listeners'
```

Conditions you'll see:

| Condition       | Means                                                            | Common failure                                                                 |
|-----------------|------------------------------------------------------------------|--------------------------------------------------------------------------------|
| `Accepted`      | EG understood the listener config                                | Unsupported `protocol:` (e.g. `HTTPS` without `tls:` block)                    |
| `ResolvedRefs`  | Every `certificateRefs[]` Secret was found, was the right type, and is readable | Secret missing, wrong type (must be `kubernetes.io/tls`), or in a different ns without a ReferenceGrant |
| `Programmed`    | EG has translated the listener and the Envoy data plane is live  | Usually follows from the above two                                             |
| `Conflicted`    | Two listeners conflict (e.g. same port + protocol + hostname)    | Two `HTTPS` listeners with identical `hostname:` and `port:`                   |

## Run with cert-manager (sidebar)

In production you almost never want a hand-rolled CA in a script.
cert-manager automates the issue + renew loop and produces the same
`kubernetes.io/tls` Secret EG expects. Equivalent manifests (NOT
applied by `make up`; install cert-manager first):

```yaml
# Issuer using a CA the cluster admin already manages.
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: local-ca, namespace: demo }
spec:
  ca: { secretName: ca-key-pair }   # Secret holding tls.crt + tls.key for the CA

---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: hello-cert, namespace: demo }
spec:
  secretName: hello-tls             # ← same name Gateway's certificateRefs points at
  dnsNames: [ hello.local ]
  issuerRef:
    name: local-ca
    kind: Issuer
  duration: 720h        # 30d
  renewBefore: 240h     # 10d  — cert-manager rotates at this remaining lifetime
```

When the Certificate object becomes `Ready: True`, cert-manager
writes/updates the `hello-tls` Secret. EG sees the Secret change
through its watch, pushes the new cert via SDS, and your HTTPS
listener serves the rotated cert without a restart.

In Phase 2 example 13 (SecurityPolicy / JWT) we revisit this with a
real cert-manager `ClusterIssuer` backed by a self-signed CA.

## Driving traffic without editing `/etc/hosts`

curl's `--resolve` flag pins one hostname to one IP for the lifetime
of the request — perfect for SNI demos:

```bash
curl -v --cacert certs/ca.crt \
  --resolve hello.local:18443:127.0.0.1 \
  https://hello.local:18443/
```

What this gives you:

- TLS handshake to `localhost:18443` with `SNI=hello.local`.
- curl validates the presented cert against `certs/ca.crt`.
- The request's `Host:` header is set to `hello.local`.
- Envoy's `filter_chain_match { server_names: [hello.local] }` wins,
  EG-generated route table dispatches to `helloworld`.

`openssl s_client -servername` is the equivalent for inspecting just
the handshake.

## Common failure modes

| Symptom                                                                      | Likely cause                                                                                                       |
|------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| Listener condition `ResolvedRefs=False reason: InvalidCertificateRef`        | Secret missing, wrong namespace, wrong type. Must be `kubernetes.io/tls` in the same ns as the Gateway.            |
| curl: `SSL certificate problem: unable to get local issuer certificate`      | Pass `--cacert certs/ca.crt`. With a real cert from cert-manager backed by Let's Encrypt etc., system trust works. |
| curl: `Could not resolve host: hello.local`                                  | Use `--resolve hello.local:18443:127.0.0.1` (or edit `/etc/hosts`).                                                |
| Wrong cert shown for an SNI (`openssl s_client` shows the other host's cert) | Either you swapped the `certificateRefs[]` or the listener `hostname:` is wrong / overlapping. Check listener status. |
| Listener condition `Conflicted=True`                                         | Two listeners share port + protocol + hostname. Make hostnames distinct.                                           |
| `make up` hangs at `kubectl wait Programmed`                                 | Likely the Secret didn't materialize. `kubectl -n demo get secret hello-tls` should exist; if not, re-run `make up`. |

## Exercises

1. **Wildcard hostname.** Change one listener's `hostname:` to
   `*.local` and use a cert with SAN `*.local`. Verify both
   `hello.local` and `api.local` hit that listener (with the same
   cert). What's the precedence if a more-specific listener
   (`hello.local`) coexists with a wildcard one (`*.local`)?

2. **Passthrough.** Switch one listener to `tls.mode: Passthrough`,
   remove `certificateRefs[]`, and put the HTTPS-aware backend (a
   pod with its own cert) behind it via a `TLSRoute` (example 07
   covers TLSRoute). Confirm Envoy never sees the plaintext payload.

3. **Cross-namespace cert.** Move `hello-tls` into another namespace
   (`tls-certs`) and add a `ReferenceGrant` permitting
   `Gateway.demo` to consume `Secret/hello-tls.tls-certs`. Example
   08 has the full walkthrough; this is the cert-flavored analogue.

4. **Renew without restart.** With the Gateway running, regenerate
   `certs/hello.local.crt` (delete it + re-run `make certs`), then
   `kubectl create secret tls hello-tls --dry-run=client -o yaml | kubectl apply -f -`.
   Watch the new fingerprint show up in `openssl s_client` output
   *without* the Envoy pods restarting. That's SDS at work.

5. **Force a Conflicted listener.** Add a third listener with
   `port: 443`, `protocol: HTTPS`, `hostname: hello.local` (same
   as `https-hello`). What does the Gateway status say? How does
   EG decide which listener "wins"?

## Cleanup

```bash
make down               # deletes Gateway, HTTPRoutes, Secrets
make clean-certs        # rm -rf certs/
```

## What's next

- [`06-grpcroute`](../06-grpcroute/) — mirrors Phase 1's gRPC
  example. Same backend story, different `protocol:` matcher.
