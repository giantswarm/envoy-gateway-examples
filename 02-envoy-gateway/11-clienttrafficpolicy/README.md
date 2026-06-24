# 11 — ClientTrafficPolicy: downstream tuning

`ClientTrafficPolicy` is Envoy Gateway's "everything-about-how-Envoy-
treats-the-client-side" CR. It attaches to a Gateway (or specific
listener) and exposes Envoy knobs that Gateway API itself doesn't:
client IP detection, HTTP/1 header casing, HTTP/2 stream limits,
HTTP/3 enable, TCP keepalive, idle timeouts, downstream mTLS,
PROXY-protocol acceptance, path normalization, and more.

This example demonstrates **three observable knobs** so you can see
the policy taking effect end-to-end:

1. `clientIPDetection.xForwardedFor.numTrustedHops` — propagate the
   real client IP from a trusted upstream proxy.
2. `http1.preserveHeaderCase` — don't lowercase HTTP/1 headers on
   the way through.
3. `path.disableMergeSlashes` — keep `/a//b` instead of collapsing
   to `/a/b`.

By the end you should be able to answer:

- What is `ClientTrafficPolicy`, what does it attach to, and how
  does it differ from `BackendTrafficPolicy` (example 12)?
- What gets verified by `clientIPDetection.xForwardedFor`, and
  what does `numTrustedHops` actually do?
- When would you turn on `http1.preserveHeaderCase`? When NOT?
- Why is the default to merge slashes — and when do you want to
  disable that?
- Where does each CTP field show up in the generated Envoy HCM?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–10.

## Run it

```bash
make up           # Gateway + HTTPRoute + ClientTrafficPolicy
make verify       # 6-section walkthrough with curl + /echo
make admin
make down
```

## Attachment

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind:  Gateway
      name:  tuned-client
      # sectionName: <listener-name>     # optional — restrict to one listener
```

- One CTP per **(Gateway, listener)** slot. A second CTP targeting
  the same target ends up `Conflicted=True`.
- Targeting `Gateway` without `sectionName` applies to **every**
  listener.
- A CTP targeting a specific listener via `sectionName` OVERRIDES
  the Gateway-level one for that listener. Same "specific wins"
  pattern as the Kubernetes Gateway API attaches policies usually
  follow.

## The CTP fields you care about

(The example's `clienttrafficpolicy.yaml` shows commented-out blocks
for the ones not exercised here.)

| Field                                                  | What it tunes                                               |
|---------------------------------------------------------|--------------------------------------------------------------|
| `clientIPDetection.xForwardedFor.numTrustedHops`        | Trust the last N hops of the incoming XFF header             |
| `clientIPDetection.customHeader`                        | Get the client IP from a custom header (e.g. `True-Client-IP`) |
| `enableProxyProtocol`                                  | Accept PROXY v1/v2 from an L4 LB in front                    |
| `http1.preserveHeaderCase`                              | Forward HTTP/1 header names in the case the client sent      |
| `http1.enableTrailers`                                  | Allow trailers on HTTP/1 connections                          |
| `http2.maxConcurrentStreams`                            | Per-connection cap (default 100)                              |
| `http2.onInvalidMessage`                                | TerminateConnection / TerminateStream                         |
| `http3.{}`                                              | Enable HTTP/3 / QUIC (needs UDP listener)                     |
| `tls.minVersion` / `tls.maxVersion` / `tls.ciphers`     | Downstream TLS posture                                        |
| `tls.clientValidation.caCertificateRefs`                | Downstream **mTLS** — require + verify client cert            |
| `path.disableMergeSlashes`                              | Keep consecutive `/` literal                                  |
| `path.escapedSlashesAction`                             | KeepUnchanged / RejectRequest / UnescapeAndForward            |
| `timeout.tcp.idleTimeout`                               | Idle TCP timeout                                              |
| `timeout.http.requestReceivedTimeout`                   | Max time to receive the request line + headers                |
| `connection.bufferLimit`                                | Per-connection buffer cap                                     |
| `headers.preserveXRequestID`                            | Don't overwrite the inbound `x-request-id`                   |

Anything affecting the **client→Envoy** side belongs here. Anything
affecting the **Envoy→backend** side belongs in
`BackendTrafficPolicy` (example 12) or `BackendTLSPolicy` (example 10).

## What the three demo knobs do

### `clientIPDetection.xForwardedFor.numTrustedHops: 1`

Without this, Envoy treats the immediate TCP peer (in kind: the
kubectl port-forward) as the client. With `numTrustedHops: 1`, it
walks **one entry back** from the right end of any inbound
`X-Forwarded-For` header and treats THAT IP as the real client.

```
Client (10.0.0.5)
  -> Cloudflare/CDN (203.0.113.42)
     adds XFF: 10.0.0.5
       -> Our LB (198.51.100.7)
          appends XFF: 10.0.0.5, 203.0.113.42
            -> Envoy Gateway
               numTrustedHops=1 -> peels 198.51.100.7 (== LB itself)
               real client = 203.0.113.42 (Cloudflare's view)
               or, with numTrustedHops=2, real client = 10.0.0.5
```

The backend also receives the XFF chain so its access logs match.
`make verify` proves the propagation by hitting helloworld's
`/echo`, which echoes the headers it saw.

### `http1.preserveHeaderCase: true`

HTTP/1.1 header names are case-insensitive per RFC. Envoy
historically lowercased everything on the wire — fine for compliant
clients, breaks legacy backends that grep for `X-MyApp` and miss
`x-myapp`. Turning this on tells Envoy to preserve the casing it
received.

There's no impact on **lookups** in Flask (which has its own
case-insensitive header dict), but the raw HTTP bytes on the wire
have the original case. Inspect with `curl -v` or via Envoy's
access log to confirm.

### `path.disableMergeSlashes: true`

Envoy's HCM normalizes `/a//b/c` → `/a/b/c` BEFORE running the route
table. With this knob set, the path is forwarded **verbatim** —
useful for apps where `//` is meaningful (e.g. some object storage
URL schemes).

**Note for this example**: helloworld's Flask app doesn't register a
`/echo//double` route, so it returns 404 either way. The
authoritative proof that the policy applied is Envoy's **access
log**, which records the path as it was forwarded:

```
GET /echo//double   <- disableMergeSlashes: true   (forwarded verbatim)
GET /echo/double    <- default (merge_slashes on)  (normalized)
```

`make verify` section 5 dumps the relevant access-log lines from
the Envoy pod so you can see which one fired.

## Verify

`make verify` walks through:

1. CTP `Accepted=True`.
2. Port-forward + baseline GET `/echo` returning 200.
3. Send `X-Forwarded-For: 203.0.113.42, 198.51.100.7` — backend
   should see the XFF (with the trusted-hop logic applied to
   Envoy's notion of the client IP).
4. Send a `X-Tutorial-Tag` header in mixed case — verify it's
   visible to the backend, and inspect response headers for casing
   evidence.
5. Hit `/echo//double` — backend sees the double slash.
6. Dump `/config_dump`: extract the HCM fields the CTP populated
   (`xff_num_trusted_hops`, `merge_slashes`, etc.).

## Common failure modes

| Symptom                                                                  | Cause                                                                                                          |
|---------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `ClientTrafficPolicy Conflicted=True`                                    | Another CTP targets the same Gateway/listener. Only one policy per slot.                                       |
| `Accepted=False reason: Invalid`                                         | Schema typo — check the path (`http1.preserveHeaderCase`, not `preserveHttp1HeaderCase`). EG validates strictly. |
| XFF propagation works, but Envoy's access log STILL shows the kubectl-port-forward IP as remote | `numTrustedHops: 0` (the default) — Envoy hasn't been told to trust the inbound XFF. Bump to 1.               |
| `Accepted=True` but no behavior change visible                           | EG may need a few seconds to push the new HCM config. Wait 2–3s, then retry. Confirm in `/config_dump` first.   |
| `clientIPDetection.customHeader` set, but the IP isn't picked up         | Header name is case-insensitive; the header value must be a single IP, no XFF-style list. Otherwise use the XFF form. |
| HTTP/3 enabled, but clients don't switch                                 | Browsers need an `Alt-Svc` header to know HTTP/3 is available, AND a UDP listener on a port matching the URL.   |

## Exercises

1. **Downstream mTLS.** Add `tls.clientValidation.caCertificateRefs[]`
   pointing at a ConfigMap with a CA cert. Make the listener HTTPS
   (cert from example 05). Try `curl --cert ... --key ...` and
   confirm the client cert is required.

2. **PROXY protocol.** Enable `enableProxyProtocol: true`. Use
   `socat` or `haproxy-test` to wrap requests in PROXY v2 framing
   and confirm Envoy parses it. (Won't work through plain `kubectl
   port-forward` — need a sidecar wrapper.)

3. **HTTP/2 stream limits.** Set
   `http2.maxConcurrentStreams: 10`. Use `h2load` or `nghttp` to
   open one HTTP/2 connection with 100 streams; observe Envoy
   reject the excess with GOAWAY.

4. **TLS 1.3 only.** Add `tls.minVersion: TLSv1.3`. Use
   `openssl s_client -tls1_2` to confirm the connection is
   rejected.

5. **Per-listener CTP.** Add a second listener (HTTPS, with example
   05's cert) and write a SECOND CTP targeting just that listener
   via `sectionName: https`. Show that the two listeners now have
   different downstream postures.

## Cleanup

```bash
make down
```

## What's next

- [`12-backendtrafficpolicy`](../12-backendtrafficpolicy/) — the
  upstream-side counterpart: retries, timeouts, circuit breakers,
  active health checks, load balancing.
