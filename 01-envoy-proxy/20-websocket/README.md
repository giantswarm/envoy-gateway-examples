# 20 — WebSocket

WebSocket is HTTP/1.1 with an Upgrade dance:

```
Client  ─► GET / HTTP/1.1
           Upgrade: websocket
           Connection: Upgrade
           Sec-WebSocket-Key: <nonce>
           Sec-WebSocket-Version: 13

Server  ◄── HTTP/1.1 101 Switching Protocols
            Upgrade: websocket
            Connection: Upgrade
            Sec-WebSocket-Accept: <derived from nonce>
```

After the 101 the TCP socket is no longer HTTP — both sides switch
to the WebSocket framing protocol.

**Envoy needs one knob** to forward this correctly:
`upgrade_configs` on the HCM listing every protocol it permits
upgrading to. Without that, Envoy passes the headers but never
flips the connection into upgrade mode — the WS handshake stalls.

## Run it

```bash
make up && make verify
make down
```

Needs `websocat` on your PATH (`brew install websocat`).

## The one knob

```yaml
http_filters: [ ... ]
upgrade_configs:
  - upgrade_type: websocket
  # - upgrade_type: CONNECT     # if you also need HTTP/2 CONNECT
route_config: { ... }
```

Multiple `upgrade_configs[]` are allowed — list every protocol
your gateway needs to forward.

## Route idle timeout

WS streams are long-lived. Envoy's default `idle_timeout` is 1
hour — fine for most cases, but stress tests / very long sessions
need a bump:

```yaml
route:
  cluster: echo
  idle_timeout: 0s     # 0 = disabled, no idle reaping
```

Real-world: pick something like `15m` so dead connections
eventually close.

## Phase 2 equivalent

Gateway API doesn't have a dedicated "WebSocket" feature — it's
just HTTP. Envoy Gateway always enables WebSocket on HTTP listeners
by default in v1.4+. The `upgrade_configs` shape isn't user-visible
in Gateway API; if you need to tune it (e.g. add HTTP/2 CONNECT),
use an `EnvoyPatchPolicy` (Phase 2 ex 18).

## Common pitfalls

- WebSocket can't traverse HTTP/2 (the spec assumes HTTP/1.1).
  HTTP/2 has its own "extended CONNECT" frame for this, but
  support varies; most production WS endpoints are HTTP/1.1 only.
- `Sec-WebSocket-Key` is opaque from Envoy's perspective; it
  passes through. The server validates it.
- TLS works fine — terminate at Envoy as usual (ex 09). The
  upgrade dance happens INSIDE the TLS session.
- Per-message timeout: there isn't one. Use `idle_timeout` on
  the route as a proxy for "user went away". A keep-alive ping
  from the client resets the timer.

## Exercises

1. Lower `idle_timeout` to 5s, leave a WS session open, watch
   Envoy reap it on the access log.
2. Add a SECOND backend and split WebSocket traffic between them
   via two routes (one per `path:`). Confirm both echo.
3. Add `upgrade_type: CONNECT` and test with an HTTP/2 client
   that uses extended CONNECT (e.g. for VPN-over-HTTP).
