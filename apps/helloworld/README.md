# helloworld

A tiny Flask app used as the backend by every example in this repo. Endpoints:

| Method | Path       | Behavior                                          |
|--------|------------|---------------------------------------------------|
| GET    | `/`        | `{"msg": "hello, world", "from": $NAME}`         |
| GET    | `/headers` | Echoes the request headers Envoy forwarded       |
| GET    | `/slow`    | Sleeps `?seconds=N` (default `2`) then responds  |
| GET    | `/fail`    | Returns HTTP `?code=N` (default `500`)           |
| ANY    | `/echo`    | Echoes method, path, headers, query, body        |

Environment:

- `NAME` — string baked into every response. Set it per replica so examples
  can tell which backend served a given request.
- `PORT` — listening port (default `8080`).
- `BREAK` — when set to `true`/`1`/`yes`, every request returns `BREAK_CODE`
  (default `500`) before reaching the normal handler. Used by the
  health-check / outlier-detection / circuit-breaker examples to stand up
  an intentionally broken backend in the same cluster.
- `BREAK_CODE` — HTTP status returned when `BREAK` is enabled.

You usually do not build or run this directly — each example wires it in via
`docker compose` (Phase 1) or as a Kubernetes Deployment (Phase 2).
