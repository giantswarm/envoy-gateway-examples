# envoy-gateway-examples

A progression of runnable, tutorial-style examples for learning **Envoy
Proxy** and **Envoy Gateway**, aimed at Giant Swarm customers.

- **Phase 1 — `01-envoy-proxy/`:** Envoy standalone in Docker. Build a mental
  model of Envoy's config (listener → filter chain → HCM → route → cluster).
- **Phase 2 — `02-envoy-gateway/`:** Envoy Gateway on a `kind` cluster. Each
  example pairs Gateway API + Envoy Gateway CRs with the Envoy config they
  generate, so the translation is always visible.
- **Phase 3 — `03-debugging/`:** Reference recipes for common failure modes.

See [`PLAN.md`](./PLAN.md) for the full example list, conventions, and
build order. Examples are not yet implemented — the plan lands first.
