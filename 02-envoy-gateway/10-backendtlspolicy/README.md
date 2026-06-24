# 10 — BackendTLSPolicy: TLS from Envoy to the upstream

Example 05 covered **downstream TLS** — the client speaks HTTPS to
Envoy, Envoy terminates. This example covers the other direction:
**upstream TLS** — Envoy speaks HTTPS to the backend, validates the
backend's cert against a CA, sets SNI.

Shape: plaintext on the client side (so the upstream-TLS lesson is
isolated), TLS on the upstream side. The backend is an
**HTTPS-only nginx** with a CA-signed cert; without
`BackendTLSPolicy` Envoy would open a plaintext connection and the
TLS handshake would fail.

By the end you should be able to answer:

- What does `BackendTLSPolicy` do, and where does it live in the
  schema?
- How does Envoy use `validation.hostname` — is it SNI, name
  verification, or both?
- What's the difference between `caCertificateRefs[]` and
  `wellKnownCACertificates: System`?
- How would you turn this into mTLS (client cert in addition)?
- What Envoy artifact does the policy translate into?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–09.
- `openssl` on your `$PATH`.

## Run it

```bash
make up           # gen-certs, Secret + ConfigMap, backend, Gateway, HTTPRoute, BTP
make verify       # 5-step walk through + live negative test
make admin
make down
```

## What `BackendTLSPolicy.spec` looks like

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha3
kind: BackendTLSPolicy
metadata: { name: ..., namespace: ... }
spec:
  # Array — one policy can target multiple Services.
  targetRefs:
    - group: ""
      kind: Service          # or `gateway.envoyproxy.io` + Backend (ex 09)
      name: secure-backend
      sectionName: https     # optional — limit to one port

  validation:
    # Trust roots. Pick ONE of these two:
    caCertificateRefs:
      - group: ""
        kind: ConfigMap      # or Secret
        name: secure-backend-ca
    # wellKnownCACertificates: System    # use the system trust store

    # SNI Envoy sends, AND hostname it expects in the cert (SAN match).
    hostname: secure-backend.tls-upstream-demo.svc.cluster.local

    # mTLS — optional; Envoy presents this cert to the backend.
    # subjectAltNames: [...]            # extra SAN constraints
```

A few rules worth memorizing:

- **One BTP per backend port.** Stacking two policies on the same
  `(Service, sectionName)` is rejected with `Conflicted=True`.
- `caCertificateRefs[]` and `wellKnownCACertificates` are mutually
  exclusive — pick one.
- The CA cert must be PEM, under the key **`ca.crt`** in the
  ConfigMap/Secret. Other names won't be picked up.
- `hostname:` is BOTH the SNI sent on the wire AND the expected SAN
  in the backend's cert. You typically set this to the in-cluster
  FQDN of the Service. Make sure the backend's cert SAN includes
  that exact name.

## How the request flows

```
   curl (plain HTTP)           Envoy data plane             nginx backend
   -----------------           ----------------             -------------
   GET http://localhost/  -->  Listener :80 (HTTP)
                                Route table: / -> cluster secure-backend
                                Cluster:
                                  type: EDS
                                  transport_socket:
                                    name: envoy.transport_sockets.tls
                                    UpstreamTlsContext {
                                      sni: secure-backend.tls-upstream-demo.svc...
                                      validation_context {
                                        trusted_ca: <CA from ConfigMap>
                                        match_typed_subject_alt_names: [DNS:...]
                                      }
                                    }
                                                    --HTTPS handshake--->
                                                    SNI=secure-backend.tls...
                                                    cert: signed-by-CA
                                                    server_name match: OK
                                                    <-- HTTPS 200 + body--
                              <-- plaintext HTTP 200 (transcribed) --
   <-- HTTPS 200 + body --
```

Envoy validates: signature chain → SAN matches `hostname:`. If any
of those fail, the cluster's endpoint goes unhealthy.

## Why the client side is plaintext here

Two reasons we keep the client side HTTP:

1. **Isolate the lesson.** Mixing downstream TLS in this example
   would mean two cert pools to debug — confusing when the goal is
   to understand the *upstream* side.
2. **kubectl port-forward.** Forwarding TCP to a plaintext listener
   makes `curl http://localhost:18110/` work without `--resolve`
   gymnastics. Less plumbing per concept.

Production traffic almost always wants both. Combining is one of
the exercises.

## The pieces

```
manifests/
├── 00-namespace.yaml             # tls-upstream-demo
├── secure-backend.yaml           # nginx with TLS only on :8443, mounts Secret
├── gateway.yaml                  # HTTP listener :80
├── httproute.yaml                # / -> secure-backend:8443
└── backendtlspolicy.yaml         # the policy itself
```

`gen-certs.sh` produces a CA + a leaf cert with SAN matching the
backend's in-cluster FQDN. `make up`:

1. Creates a `kubernetes.io/tls` Secret with the leaf cert/key for
   nginx to mount.
2. Creates a plain ConfigMap holding the CA cert (key `ca.crt`)
   for the BTP to reference.

## Verify steps

`make verify` runs:

1. Gateway / HTTPRoute / BTP all show their respective Accepted
   conditions.
2. Plaintext `curl http://localhost:18110/` works → Envoy
   terminated nothing, but spoke HTTPS to nginx.
3. Dump the Envoy cluster: `transport_socket.name` is
   `envoy.transport_sockets.tls`, with `sni:` and a populated
   `common_tls_context`.
4. **Negative test**: delete the BTP, watch traffic fail. The
   most common failure code is **400** — nginx's "The plain HTTP
   request was sent to HTTPS port" response (it sees Envoy's
   plaintext bytes on its TLS port). 5xx / `000` / `ERR` are also
   possible depending on what nginx decides to do with the
   non-TLS bytes. Re-apply, watch recovery to 200.
5. Side-by-side mapping table — downstream vs upstream vs
   end-to-end vs passthrough.

## Common failure modes

| Symptom                                                                 | Cause                                                                                                            |
|--------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------|
| `BackendTLSPolicy Accepted=False reason: Invalid` / `RefNotPermitted`   | Cross-ns ConfigMap/Secret without a ReferenceGrant; or CA file key isn't `ca.crt`.                              |
| 502/503 from the data plane, BTP reports `Accepted=True`                | Likely SAN mismatch. `validation.hostname` must equal the SAN in the cert. Inspect with `openssl x509 -noout -text -in certs/backend.crt | grep -A1 'Subject Alternative Name'`. |
| `upstream_reset_before_response_started{tls\|certificate_validation_failed}` | Trust chain broken — wrong CA in the ConfigMap, or the leaf cert was reissued and the CA wasn't updated.        |
| Two BTPs targeting the same Service → one `Conflicted=True`             | At most ONE BTP per (Service, port). Merge them into one.                                                       |
| Backend returns `400 The plain HTTP request was sent to HTTPS port`     | nginx is receiving plaintext on its TLS-only port — i.e. the BTP isn't taking effect. Check that the BTP `Accepted=True` and `targetRefs.name` exactly matches the Service. Re-apply if EG hasn't reconciled. |
| Cert SAN includes `secure-backend` but BTP hostname is FQDN — works locally, fails after move | SAN should include BOTH short and long forms when in doubt. `gen-certs.sh` here includes 3 SAN entries.         |

## Exercises

1. **mTLS.** Add a `tls.clientCertificateRef:` to the BTP pointing
   at a Secret holding Envoy's client cert. Configure nginx with
   `ssl_verify_client on` + `ssl_client_certificate`. Show that
   Envoy now presents the cert and nginx accepts the connection.

2. **System trust store.** Replace `caCertificateRefs[]` with
   `wellKnownCACertificates: System`. Repoint the HTTPRoute at the
   external `Backend/example-com` from example 09 (port 443).
   Now you're doing one-way TLS to a publicly-signed endpoint —
   no custom CA needed.

3. **End-to-end TLS.** Turn the Gateway listener into HTTPS (with
   a cert from example 05). Combine downstream-TLS + upstream-TLS.
   Verify with `curl --cacert ...` from the client side.

4. **Per-port BTP.** Add a second port to the Service (HTTP on
   8080, kept available alongside the HTTPS one). Attach the BTP
   to only the `https` port via `sectionName: https`. Show the
   HTTP port still works without TLS.

5. **Reissue the cert.** Without restarting nginx or Envoy:
   regenerate `certs/backend.crt`, update the Secret. Confirm
   nginx picks it up (it watches the file). Now also update the
   CA in the ConfigMap (regenerate it too) and re-issue. Confirm
   Envoy picks up the new CA via EG's reconcile.

## Cleanup

```bash
make down
make clean-certs
```

## What's next

- [`11-clienttrafficpolicy`](../11-clienttrafficpolicy/) — the
  downstream-tuning counterpart: connection limits, proxy protocol,
  HTTP/3, client cert auth.
