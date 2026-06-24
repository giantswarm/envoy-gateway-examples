# 03 — Routing basics

The route table starts doing real work. Same one listener, one cluster as
the previous examples; we're rebuilding the `virtual_hosts` block to show
how Envoy actually picks a route, transforms the request, and chooses an
action.

By the end of this example you should be able to answer:

- How does Envoy pick a virtual host?
- What are the match types (`prefix`, `path`, `safe_regex`,
  `path_separated_prefix`) and when does each fit?
- How do I gate a route on a header or a query parameter?
- What's the difference between a `route`, a `redirect`, and a
  `direct_response`?
- How do `prefix_rewrite` and `regex_rewrite` change the URL the backend
  sees?
- **Why does ordering matter so much?**

## Prerequisites

- Done [`01`](../01-helloworld-static/) and [`02`](../02-config-anatomy/).
- Docker, `docker compose`, `curl`, `jq`.

## Run it

```bash
make up
make verify   # exercises every route in envoy.yaml
make down
```

## The matching pipeline

A request goes through three levels of matching before it reaches a
backend:

```
HTTP request
   │
   ▼
┌─────────────────────────┐
│  virtual_host           │  matched by Host / :authority header
│  (e.g. "api.local")     │  -> domains: ["api.local"]
└─────────────────────────┘
   │
   ▼
┌─────────────────────────┐
│  routes[] (in order)    │  first whose `match {}` block satisfies wins
│  match by:              │  ┌── path / prefix / safe_regex
│   path                  │  │   path_separated_prefix
│   headers (AND)         │  │
│   query_parameters (AND)│  │
│   :method (as a header) │  │
└─────────────────────────┘
   │
   ▼
┌─────────────────────────┐
│  action                 │  one of:
│                         │   route { cluster: ..., prefix_rewrite: ... }
│                         │   redirect { ... }
│                         │   direct_response { ... }
└─────────────────────────┘
```

### Picking the virtual host

```yaml
virtual_hosts:
  - name: api
    domains: ["api.local"]
    routes: [...]
  - name: local_service
    domains: ["*"]
    routes: [...]
```

Envoy looks at the `:authority` pseudo-header (HTTP/2) or `Host:` header
(HTTP/1.1) and picks the most specific matching `domains:` entry. Matching
goes: **exact** > **suffix wildcard** (`*.example.com`) > **prefix wildcard**
(`example.*`) > **`*`** catch-all. With our two virtual hosts:

- `curl -H "Host: api.local" ...` → `api`.
- Anything else → `local_service`.

> **You always want a `domains: ["*"]` virtual host last.** Without a
> catch-all, requests for unknown hosts get a `404` from Envoy *before*
> the route table is consulted — easy to miss in tests until you ship.

### Matching a route

Inside one virtual host, routes are scanned **top to bottom**. The **first**
route whose `match {}` block is satisfied wins. Any combination of these
matchers can appear; they are AND-ed:

| Matcher                 | What it matches                                                |
|-------------------------|----------------------------------------------------------------|
| `prefix`                | Path starts with the given string. `/api` matches `/api/v1/x`. |
| `path`                  | Exact path match.                                              |
| `safe_regex`            | RE2 regex against the whole path.                              |
| `path_separated_prefix` | Prefix only on segment boundaries — `/api` matches `/api` and `/api/x` but **not** `/apiv2`. Avoids the classic `/api` vs `/apiv2` bug. |
| `headers`               | List of header matchers; all must match. Includes `:method`.   |
| `query_parameters`      | List of query-param matchers; all must match.                  |
| `dynamic_metadata`      | Match on metadata set by earlier filters. (Advanced.)         |

### Choosing an action

A matched route does one of three things:

- **`route:`** — forward to a cluster. May include `prefix_rewrite`,
  `regex_rewrite`, `host_rewrite_literal`, `request_headers_to_add`,
  `request_headers_to_remove`, `response_headers_to_add`,
  `response_headers_to_remove`, retry policy, timeout, hash policy, …
- **`redirect:`** — return a 3xx with a constructed Location. Supports
  `path_redirect`, `prefix_rewrite`, `host_redirect`, `port_redirect`,
  `https_redirect: true`, and the response code (`MOVED_PERMANENTLY`,
  `FOUND`, `SEE_OTHER`, `TEMPORARY_REDIRECT`, `PERMANENT_REDIRECT`).
- **`direct_response:`** — return a fixed response (status + optional
  body) without going upstream. Cheap healthchecks, maintenance pages,
  and "always 401 unless gated" patterns live here.

## Walkthrough of `envoy.yaml`

The catch-all virtual host has **seven** routes. Read them in order — that
ordering IS the policy.

### Route 1 — `path: /healthz` + `direct_response`

```yaml
- match: { path: "/healthz" }
  direct_response:
    status: 200
    body: { inline_string: "ok\n" }
```

Exact-match on `/healthz`, fixed `200 ok`. The backend never sees this.
This is what you point a Kubernetes liveness probe at when the proxy is
the front door — saves a round-trip.

### Route 2 — `prefix: /api/v1/` + `prefix_rewrite: /`

```yaml
- match: { prefix: "/api/v1/" }
  route: { cluster: helloworld_cluster, prefix_rewrite: "/" }
```

`/api/v1/echo` → backend sees `/echo`. The `prefix_rewrite` replaces only
the matched prefix; the rest of the path is preserved.

### Route 3 — `redirect`

```yaml
- match: { prefix: "/legacy" }
  redirect:
    path_redirect: "/api/v1"
    response_code: MOVED_PERMANENTLY
```

`/legacy/anything` → `301 Location: /api/v1`. Useful for sun-setting old
paths without code changes.

### Routes 4 + 5 — header-gated, with ordering

```yaml
- match:
    prefix: "/admin"
    headers:
      - name: x-api-key
        string_match: { exact: hunter2 }
  route:
    cluster: helloworld_cluster
    regex_rewrite:
      pattern: { regex: "^/admin(/.*)?$" }
      substitution: "/echo"
- match: { prefix: "/admin" }
  direct_response: { status: 401, body: { inline_string: "unauthorized\n" } }
```

The header-gated route is **above** the catch-all 401. First match wins.
If you swapped these two routes, the gate would be unreachable — every
`/admin/*` request would fall into the 401 first and never see the
header check. This is one of the most common routing bugs.

Note the second rewrite mechanism: `regex_rewrite` instead of route 2's
`prefix_rewrite`. The two behave differently:

- **`prefix_rewrite`** replaces only the matched prefix and **keeps the
  suffix**. `prefix: "/admin"` + `prefix_rewrite: "/echo"` would turn
  `/admin/secret` into `/echo/secret` — and the backend's `/echo` is an
  exact route, so it would 404.
- **`regex_rewrite`** rewrites the **whole path** via an RE2 substitution.
  Here `^/admin(/.*)?$` → `/echo` collapses every `/admin` and `/admin/*`
  request down to `/echo`, which is what we want.

Rule of thumb: reach for `prefix_rewrite` when you're peeling a fixed
prefix off and forwarding the rest, and `regex_rewrite` when the target
path isn't a simple prefix swap (path rewriting, capture-group
substitution, query-param munging — see Exercise 1).

> **String matchers** appear all over Envoy. The shape is:
>
> ```yaml
> string_match:
>   exact: "..."        # or
>   prefix: "..."       # or
>   suffix: "..."       # or
>   contains: "..."     # or
>   safe_regex: { regex: "..." }
> ignore_case: true     # optional
> ```

### Route 6 — query-param match + header injection

```yaml
- match:
    prefix: "/q"
    query_parameters:
      - name: debug
        string_match: { exact: "true" }
  route:
    cluster: helloworld_cluster
    prefix_rewrite: "/echo"
  request_headers_to_add:
    - header: { key: x-debug, value: "on" }
      append_action: OVERWRITE_IF_EXISTS_OR_ADD
```

`/q?debug=true` matches; `/q` (no query) does not. Envoy adds an `x-debug:
on` request header that the backend can read. `append_action` modes:

Note we use `prefix_rewrite` here even though the backend's `/echo` is an
exact route — the verify script hits `/q` (no suffix), so the peel
collapses cleanly to `/echo`. Hitting `/q/foo?debug=true` would rewrite
to `/echo/foo` and 404 on the backend, same gotcha as routes 4+5.

- `APPEND_IF_EXISTS_OR_ADD` — append as a separate header value.
- `ADD_IF_ABSENT` — only add if not already there.
- `OVERWRITE_IF_EXISTS_OR_ADD` — replace.
- `OVERWRITE_IF_EXISTS` — replace only if it exists, do nothing otherwise.

### Route 7 — catch-all

```yaml
- match: { prefix: "/" }
  route: { cluster: helloworld_cluster }
```

Anything we didn't match above goes to the backend untouched.

### Virtual host 2 — `api.local`

```yaml
- name: api
  domains: ["api.local"]
  routes:
    - match: { prefix: "/" }
      route:
        cluster: helloworld_cluster
        regex_rewrite:
          pattern: { regex: ".*" }
          substitution: "/echo"
```

Pinned to one host header. Every path on `api.local` lands at `/echo` so
the rewrite is visible in the body. Same `regex_rewrite` pattern as route
4: we need to *replace* the path, not peel a prefix — `prefix_rewrite`
would have kept the suffix and 404'd the backend.

## Verify

`make verify` exercises every route. Read [`verify.sh`](./verify.sh). Things
to notice in the output:

- `/healthz` returns `ok\n` and **no `x-envoy-upstream-service-time` header
  in the access log** — Envoy answered without going upstream.
- `/api/v1/echo` makes the backend's `path` field show `/echo`, not
  `/api/v1/echo` — the rewrite happened *after* matching.
- `/legacy/anything` returns 301 with `Location: /api/v1` — not
  `/api/v1/anything`. `path_redirect` is literal; use `prefix_rewrite`
  inside `redirect:` if you want to preserve the suffix.
- `/admin/secret` without the header → 401. With the header → 200 and the
  backend sees `/echo`.
- `/q?debug=true` → backend sees `path=/echo`, `args.debug=true`, and
  a new header `x-debug: on`.

## Debugging tip — when a route "doesn't match"

When you change the route table and a request stops working, in order:

1. **Check the listener access log.** `%RESPONSE_FLAGS%` of `NR` means
   *no route matched*. `RESPONSE_CODE` of `404` from Envoy (no
   `x-envoy-upstream-service-time` set) means *no virtual host matched*.
2. **Hit `/stats?filter=vhost`.** Per-vhost counters tell you which vhost
   the request landed in.
3. **Hit `/config_dump?include_eds`** and pull out the route table:

   ```bash
   curl -s localhost:9901/config_dump \
     | jq '.configs[] | select(."@type" | endswith("RoutesConfigDump"))
                       | .static_route_configs[].route_config.virtual_hosts'
   ```

4. **Order, order, order.** Routes are linear-scan, first match wins.

## Exercises

1. **Regex match.** Add a route that matches `^/users/[0-9]+$` and
   rewrites it to `/echo` while preserving the captured user ID:

   ```yaml
   - match:
       safe_regex: { regex: "^/users/([0-9]+)$" }
     route:
       cluster: helloworld_cluster
       regex_rewrite:
         pattern: { regex: "^/users/([0-9]+)$" }
         substitution: "/echo?user_id=\\1"
   ```

   Verify with `curl http://localhost:10000/users/42 | jq .args`.

2. **Method matching.** Add a route that returns `405` for any non-`GET`
   on `/healthz`. Hint: `:method` is a header, matched like any other.

3. **Path-segment prefix.** Change route 2's `prefix: "/api/v1/"` to
   `path_separated_prefix: "/api/v1"` and verify that `/api/v1/echo`
   still matches but `/api/v1foo` does not.

4. **Reverse the ordering.** Swap routes 4 and 5. Restart, then send the
   gated request:

   ```bash
   curl -i -H "x-api-key: hunter2" http://localhost:10000/admin/secret
   ```

   What status does it return? Why?

## Cleanup

```bash
make down
```

## What's next

- **`04-load-balancing`** — multiple helloworld replicas behind one
  cluster; round-robin, least-request, ring-hash.
