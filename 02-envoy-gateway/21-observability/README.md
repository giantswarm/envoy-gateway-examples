# 21 — Observability: access logs, metrics, traces

All three observability pillars wired up at once via a per-Gateway
**`EnvoyProxy.spec.telemetry`** block:

1. **Access logs** in JSON to the envoy pod's stdout (visible via
   `kubectl logs`).
2. **Prometheus metrics** scraped from the admin endpoint.
3. **OTLP traces** sent to an in-cluster **OpenTelemetry Collector**
   with the `debug` exporter — so traces show up in the collector's
   own stdout (no Jaeger UI required to verify).

By the end you should be able to answer:

- Where in EG's CRDs do you configure access logs / metrics /
  tracing?
- How do EG's `telemetry.*` blocks translate into Envoy's HCM
  fields?
- What's the difference between sending access logs to a File
  sink vs an OpenTelemetry sink?
- What's the `samplingRate` field, and what's the right value for
  production?
- Why does this example use a PER-GATEWAY EnvoyProxy instead of
  patching the cluster default?

## Prerequisites

- [`00-kind-bootstrap`](../00-kind-bootstrap/) cluster is up.
- Done examples 01–20.

## Run it

```bash
make up           # OTel collector + per-Gateway EnvoyProxy + Gateway + HTTPRoute
make verify       # 6-section walkthrough
make logs         # tail the JSON access log
make traces       # tail the OTel Collector's trace export
make metrics      # snapshot a few Envoy metrics
make down
```

## Per-Gateway, not cluster-default

The bootstrap installs a minimal `default-envoyproxy` at the
GatewayClass level. Modifying it would affect every other example
in the cluster. Instead, this example creates `observed-proxy` and
attaches it via `Gateway.spec.infrastructure.parametersRef`.

Remember the **full-replace** rule from example 04: when a per-
Gateway EnvoyProxy is referenced, it ENTIRELY supersedes the
default. So `observed-proxy` restates `envoyService.type:
ClusterIP` — otherwise the Service defaults to LoadBalancer and
the Gateway stays at `Programmed=False / AddressNotAssigned` on
kind.

## Access logs

```yaml
accessLog:
  settings:
    - format:
        type: JSON
        json:
          start_time: "%START_TIME%"
          method: "%REQ(:METHOD)%"
          path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
          status: "%RESPONSE_CODE%"
          duration_ms: "%DURATION%"
          # ... etc.
      sinks:
        - type: File
          file:
            path: /dev/stdout
```

Each entry in `json:` becomes one field in the emitted JSON object.
The values are Envoy log substitution strings — see
[envoyproxy.io/.../access_log/usage](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage).
Sink options:

| Sink type        | Use case                                                                       |
|-------------------|--------------------------------------------------------------------------------|
| `File`            | stdout (containers!) or a path inside the pod — pick stdout for K8s log shippers |
| `OpenTelemetry`   | Send the logs (yes, logs) as OTLP to the same collector that gets traces       |
| `ALS`             | gRPC access log service                                                        |

Format `type: Text` is the alternative — Envoy's default
single-line text format. JSON is structured and parser-friendly.

## Metrics

EG's data plane exposes Prometheus metrics on the admin port at
**`/stats/prometheus`**. The admin port itself is 19001 (port 19000
is the regular admin); EG splits them so you can scrape metrics
without exposing the full admin interface.

```yaml
metrics:
  prometheus:
    disable: false       # default — leave it on
  matches:               # OPTIONAL — limit which stats are exposed
    - type: Counter
      name: envoy_http_downstream_rq_total
```

`make metrics` greps a handful out of the endpoint so you can see
what the format looks like. In production, you'd add a
`ServiceMonitor` (Prometheus Operator) pointing at the
auto-generated data-plane Service.

## Tracing

```yaml
tracing:
  samplingRate: 100                      # 0-100 percent
  provider:
    type: OpenTelemetry
    backendRefs:
      - name: otel-collector
        namespace: demo
        port: 4317                       # OTLP gRPC
  customTags:
    env:
      type: Literal
      literal: { value: tutorial }
    pod_name:
      type: Environment
      environment:
        name: ENVOY_POD_NAME
        defaultValue: unknown
```

- `samplingRate` is a **percentage**, not a fraction. `100` =
  sample everything. Real-world: `1` to `10` is normal at high RPS;
  drop further if your tracing backend gets expensive.
- `provider.backendRefs` is an in-cluster Service ref — same shape
  as anywhere else. We add `appProtocol: kubernetes.io/h2c` to the
  Service so EG knows to talk HTTP/2 (OTLP gRPC requires HTTP/2).
- `customTags` add literal or env-derived labels to every span.

The OTel Collector in this example uses the `debug` exporter to
print spans to its own stdout — `make traces` tails them. For
production, swap that for an `otlp` or `jaeger` or `tempo`
exporter pointing at your real tracing backend.

## The pieces

```
manifests/
├── otel-collector.yaml      # ConfigMap + Deployment + Service for the collector
├── envoyproxy.yaml          # per-Gateway EnvoyProxy with telemetry.*
├── gateway.yaml             # Gateway -> infrastructure.parametersRef
└── httproute.yaml           # / -> helloworld
```

`make up` brings the collector up FIRST (so when EG configures
Envoy with the OTLP exporter, the target is already accepting
connections). The EnvoyProxy is applied next, then the Gateway and
route.

## Verify

`make verify` runs 6 sections:

1. Gateway Programmed, OTel Collector Ready.
2. Port-forward + send 5 tagged requests.
3. Grep the envoy pod logs for our tag → expect 5 JSON entries.
4. Pull `/stats/prometheus` → confirm
   `envoy_http_downstream_rq_total` is present.
5. Grep the OTel Collector logs for trace markers → expect
   spans to have been printed.
6. Mapping table from telemetry fields to Envoy artifacts.

## Common failure modes

| Symptom                                                                | Cause                                                                                                |
|-------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------|
| `Gateway Programmed=False reason: AddressNotAssigned`                   | Per-Gateway EnvoyProxy didn't restate `envoyService.type: ClusterIP` (full-replace rule, see ex 04). |
| Access logs are still plain text                                        | Stale data plane — EG rolled the deployment, but `kubectl logs` is showing the previous container.   |
| Trace spans never reach the collector                                   | `appProtocol: kubernetes.io/h2c` missing on the otel-collector Service port (OTLP gRPC needs HTTP/2). Confirm with `kubectl -n demo logs deploy/otel-collector` for receive errors. |
| `/stats/prometheus` returns 404 or 503                                  | Wrong port — admin is 19000, metrics endpoint is on 19001 by default in EG.                          |
| samplingRate works out at <1% of requests                               | Envoy's tracing pipeline has multiple sampling stages. If you set 100% and still see <100%, an upstream proxy is dropping some. Check `make admin` → `/clusters` for tracing stats. |
| OTel Collector pod is OOM-killed                                        | Bump the limits in `otel-collector.yaml`. With the `debug` exporter at high RPS, it can chew memory.|

## Exercises

1. **Lower the sampling rate.** Set `samplingRate: 10` and send
   100 requests. Count trace IDs in the collector logs — should
   be ~10. Real production uses 0.1–5%.

2. **Access logs to OTel too.** Change the access log sink from
   `File` to `OpenTelemetry` pointing at the same collector. Now
   both logs and traces flow over OTLP. Look at the collector's
   debug output — you'll see two pipelines.

3. **Custom log format per route.** Make TWO access-log
   `settings[]` entries: one for `path: /admin` with extra fields,
   one default. (Hint: EG might not support per-route log filtering
   directly; consult the EnvoyProxy reference.)

4. **Prometheus ServiceMonitor.** Install prometheus-operator
   (`helm install`) and add a `ServiceMonitor` selecting the EG
   data-plane Service. Confirm Prometheus is scraping it.

5. **Jaeger UI.** Replace the OTel Collector with `jaegertracing/all-in-one`
   (memory storage), expose its :16686 UI, port-forward, see the
   spans in a browser. Wire the EnvoyProxy `tracing.provider` to
   the Jaeger collector.

## Cleanup

```bash
make down
```

## What's next

- [`22-listenersets`](../22-listenersets/) — the headline new
  Gateway API feature: `XListenerSet` for sharing one Gateway
  across teams.
