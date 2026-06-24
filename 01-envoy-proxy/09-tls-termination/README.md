# 09 — Downstream TLS termination + SNI

Two listeners, two backends, two certs. The plaintext listener on
`:10000` is just there as a sanity check; the real work happens on
`:10443` where Envoy terminates TLS, sniffs the SNI from the
`ClientHello`, and uses **`filter_chain_match.server_names`** to pick
the right filter chain — *and* therefore the right certificate, the
right HCM, and the right upstream cluster.

By the end of this example you should be able to answer:

- Where does TLS configuration live in Envoy's config tree?
- What's the difference between a `transport_socket` and an `http_filter`?
- How does the TLS Inspector listener filter work, and when do you
  need it?
- How would you add mutual TLS (client certs)?
- What's TLS passthrough and when is it the right choice?
- How do I diagnose "wrong cert presented" / "handshake fails"?

## Prerequisites

- Done [`01`](../01-helloworld-static/) through
  [`08`](../08-fault-injection/).
- Docker, `docker compose`, `curl`, `jq`, `openssl`.

## Run it

```bash
make up           # generates certs (idempotent) then starts the stack
make verify       # ten-step TLS + SNI walkthrough
make down

# nuke the generated certs (re-generate next `make up`)
make clean-certs
```

`make up` runs `gen-certs.sh` first; it creates a small example CA in
`certs/` and signs two leaf certs (`one.local.crt`, `two.local.crt`).
The directory is `.gitignored` — never commit certs from a tutorial.

The verify script uses `curl --resolve` instead of editing `/etc/hosts`,
and `openssl s_client` to confirm the *actual* cert Envoy presented for
each SNI value.

## Where TLS lives in the config

Compare two pieces of config you've already met:

| Layer            | Filter type   | Purpose                                          |
|------------------|---------------|--------------------------------------------------|
| Listener         | `listener_filter` | Run before any byte is read (e.g. inspect the ClientHello) |
| Filter chain     | `transport_socket` | Decrypt/encrypt bytes coming off the wire   |
| Filter chain     | `filter` (`network`) | Process plaintext bytes (HCM lives here)  |
| Inside HCM       | `http_filter` | Process parsed HTTP requests                     |

TLS is a **transport socket**, attached to a **filter chain**. The
network/HTTP filters above it never see ciphertext — they only run on
the decrypted byte stream the TLS transport socket produces.

```yaml
filter_chains:
  - filter_chain_match: { server_names: ["one.local"] }
    transport_socket:                                            # <- TLS sits here
      name: envoy.transport_sockets.tls
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
        common_tls_context:
          alpn_protocols: ["h2", "http/1.1"]
          tls_certificates:
            - certificate_chain: { filename: "/etc/envoy/certs/one.local.crt" }
              private_key:       { filename: "/etc/envoy/certs/one.local.key" }
    filters:
      - name: envoy.filters.network.http_connection_manager
        ...
```

Two TLS proto types you'll see:

- **`DownstreamTlsContext`** — Envoy is the server (clients connect *to*
  Envoy). This example.
- **`UpstreamTlsContext`** — Envoy is the client (Envoy connects *to* a
  TLS upstream). Phase 2 covers this on the `BackendTLSPolicy` CR.

## SNI selection and the TLS Inspector

```yaml
listener_filters:
  - name: envoy.filters.listener.tls_inspector
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.listener.tls_inspector.v3.TlsInspector
```

`filter_chain_match.server_names` matches against the SNI string. But
SNI lives inside the TLS `ClientHello`, which Envoy hasn't decrypted
yet at filter-chain-selection time. The **TLS Inspector** is a
*listener filter* that peeks at the raw `ClientHello` bytes and exposes
the SNI (and the ALPN list) to the chain selector.

Without it, `server_names` never matches anything → either no chain is
selected (connection closed) or a default chain wins for everything.
You'll see a config_dump warning, plus the stat
`listener.0.0.0.0_10443.no_filter_chain_match`.

There's also `http_inspector` for HTTP/1.1 vs HTTP/2 detection on
plaintext listeners; same idea, different protocol.

## Cert delivery options

```yaml
tls_certificates:
  - certificate_chain: { filename: "/etc/envoy/certs/one.local.crt" }
    private_key:       { filename: "/etc/envoy/certs/one.local.key" }
```

Three ways to give Envoy a cert:

- **`filename:`** — Envoy reads the file at startup and on certain xDS
  events. Doesn't watch the file; rotating requires a hot restart.
- **`inline_string:`** / **`inline_bytes:`** — paste the cert directly
  into the config. Fine for tests; obviously bad for production.
- **`sds`** (Secret Discovery Service) — Envoy fetches secrets from an
  SDS server, supports rotation without restart. This is what Envoy
  Gateway uses under the hood for cert-manager / TLS secrets.

In Phase 2 we won't write any of this by hand — the `Gateway` resource
just references a Kubernetes TLS secret and Envoy Gateway translates
it into an SDS config under the covers.

## What the verify script demonstrates

| Step | What it shows                                                            |
|------|--------------------------------------------------------------------------|
| 1    | Plaintext baseline — backends respond as expected                        |
| 2    | TLS to `one.local` → routes to `cluster_one` → backend `hello-one`        |
| 3    | TLS to `two.local` → routes to `cluster_two` → backend `hello-two`        |
| 4    | `openssl s_client -servername one.local` confirms cert CN/SAN              |
| 5    | Same handshake with SNI=`two.local` presents the *other* cert              |
| 6    | SNI=`wrong.local` — Envoy closes the connection at the listener level    |
| 7    | No `--cacert` — curl rejects unknown CA; **don't** use `-k` to bypass    |
| 8    | `/certs` admin endpoint lists subject + SANs + days-until-expiration     |
| 9    | `/listeners` shows the new HTTPS listener                                 |
| 10   | Per-chain stats: `ingress_https_one.*` and `ingress_https_two.*` separately |

## Diagnosing TLS issues

A quick triage table when things go wrong:

| Symptom                                  | Likely cause                                                        |
|------------------------------------------|---------------------------------------------------------------------|
| `curl: (60) SSL certificate problem`     | curl can't chain to a trusted CA. Use `--cacert ca.crt`.            |
| `curl: (35) error:0A000410:SSL routines` | Cipher / TLS version mismatch. Try `--tlsv1.2`. Check `tls_minimum_protocol_version`. |
| `Connection reset by peer`               | No matching filter chain (SNI mismatch). Check `tls_inspector` is present. |
| Wrong cert presented for hostname        | `filter_chain_match.server_names` wrong, or you forgot `tls_inspector`. |
| `unable to get local issuer certificate` | Your cert was signed by a CA the client doesn't trust.              |
| Server `bad record MAC`                  | TLS state desync — usually a client-side issue, sometimes ALPN.    |

Live debugging:

```bash
# Show the handshake step by step
openssl s_client -connect 127.0.0.1:10443 -servername one.local \
  -alpn h2,http/1.1

# Decode a cert
openssl x509 -in certs/one.local.crt -noout -text

# What Envoy thinks it loaded
curl -s localhost:9901/certs | jq

# Did chain selection actually work?
curl -s 'localhost:9901/stats?filter=listener\.0\.0\.0\.0_10443'
```

## Production hygiene

This example is tutorial-grade. Things you'd add in production:

- **TLS version floor.** `tls_params.tls_minimum_protocol_version: TLSv1_2`
  (or 1.3) at minimum. The default depends on the Envoy build.
- **Cipher allow-list.** `cipher_suites: [...]` to lock to vetted suites.
- **Cert rotation.** Use SDS (or Envoy Gateway / cert-manager in Phase 2).
- **OCSP stapling.** `ocsp_staple` + `ocsp_staple_policy`.
- **No `inline_*` certs.** Filenames + SDS only.
- **Cert validity alerting.** Page on the `days_until_expiration` stat.

## Exercises

1. **mTLS (client certs).** Add a `validation_context` requiring the
   client to present a cert signed by our CA:

   ```yaml
   common_tls_context:
     tls_certificates: [...]
     validation_context:
       trusted_ca: { filename: "/etc/envoy/certs/ca.crt" }
       match_typed_subject_alt_names:
         - san_type: DNS
           matcher: { exact: "client.local" }
   require_client_certificate: true
   ```

   Generate a client cert and key with `gen-certs.sh` style commands,
   then `curl --cert client.crt --key client.key ...`. What happens
   without the client cert?

2. **TLS passthrough.** Add a third listener (`:10444`) that does NOT
   terminate TLS — it forwards the encrypted bytes to a backend that
   speaks TLS itself. Replace the HCM with a `tcp_proxy`:

   ```yaml
   filter_chains:
     - filter_chain_match: { server_names: ["pass.local"] }
       filters:
         - name: envoy.filters.network.tcp_proxy
           typed_config:
             "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
             stat_prefix: passthrough
             cluster: tls_backend_cluster
   ```

   When would you choose passthrough over termination? (Hint: you don't
   need to read the request, you can't see metrics per request, you
   can't inject filters — but you also don't need to manage the cert.)

3. **ALPN downgrade.** Change the chain's `alpn_protocols` to
   `["http/1.1"]` only. `curl -v --http2` against it — what does the
   handshake do?

4. **Inline cert.** Replace the `filename:` references with
   `inline_string:` and the cert PEM. Verify the config still loads.
   What's the operational risk?

5. **Different cert per SNI.** Reuse the `two.local` cert in the
   `one.local` chain. Hit the URL — does the connection still complete?
   What does the cert's SAN look like? (Demonstrates that the cert
   *chain* and *SNI selection* are independent — a malformed setup
   serves a cert that doesn't match the hostname.)

## Cleanup

```bash
make down
make clean-certs    # optional — re-generated next `make up`
```

## What's next

- **`10-rate-limiting-local`** — `local_ratelimit` HTTP filter. Token
  buckets without an external service.
