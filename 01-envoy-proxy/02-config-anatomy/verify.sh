#!/usr/bin/env bash
#
# Guided tour of the Envoy admin endpoints. Reads-only by default — none of
# these commands change state. The README explains each section in depth.
#
# Requires: curl, jq.

set -euo pipefail

ADMIN="http://localhost:9901"
DATA="http://localhost:10000"

hr()  { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
sub() { printf '\n\033[1;36m-- %s --\033[0m\n' "$*"; }

# Precondition: Envoy must be reachable on the admin port. If it isn't,
# nothing else in this script can succeed; print a friendly hint and exit.
if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.

Things to check:

  1. Did you start the stack?       make up
  2. Are the containers running?    docker compose ps
  3. Did Envoy crash on startup?    docker compose logs envoy | tail -30
  4. Is :10000 or :9901 already in use by another example?
                                    lsof -i :10000 -i :9901
     If so, stop the other one:     (cd ../<other-example> && make down)

EOF
  exit 1
fi

# At least one request through Envoy so counters in /stats are non-zero.
curl -sS -o /dev/null "${DATA}/" || true

hr "1. /ready  — readiness probe"
echo "Use as: Kubernetes readinessProbe target. Returns 200 LIVE when serving."
curl -sS "${ADMIN}/ready" || true
echo

hr "2. /server_info  — Envoy version, build, state, hot-restart epoch"
curl -sS "${ADMIN}/server_info" | jq '{version, state, hot_restart_version, command_line_options: (.command_line_options | {service_cluster, service_node, log_level})}'

hr "3. /listeners  — what's bound (text and json)"
sub "Text:"
curl -sS "${ADMIN}/listeners"
sub "JSON:"
curl -sS "${ADMIN}/listeners?format=json" | jq .

hr "4. /clusters  — clusters and their endpoints, live"
sub "Filtered to our one cluster (default text format):"
# `|| true` because head closes the pipe early -> curl exits with SIGPIPE
# (23) -> pipefail kills the script. Benign truncation, ignore.
curl -sS "${ADMIN}/clusters?cluster=helloworld_cluster" | head -30 || true
sub "JSON view of just helloworld_cluster:"
curl -sS "${ADMIN}/clusters?format=json" \
  | jq '.cluster_statuses[] | select(.name=="helloworld_cluster")'

hr "5. /stats  — counters, gauges, histograms"
sub "Per-cluster counters (filtered):"
curl -sS "${ADMIN}/stats?filter=cluster.helloworld_cluster"
sub "Per-listener counters:"
curl -sS "${ADMIN}/stats?filter=listener.0.0.0.0_10000"
sub "Histogram summary for upstream request times:"
curl -sS "${ADMIN}/stats?filter=upstream_rq_time"
sub "Prometheus format (first 12 lines):"
curl -sS "${ADMIN}/stats/prometheus" | head -12 || true

hr "6. /config_dump  — full live config"
sub "Listing the sections present:"
curl -sS "${ADMIN}/config_dump" | jq '[.configs[]."@type"]'
sub "Bootstrap section only:"
curl -sS "${ADMIN}/config_dump" \
  | jq '.configs[] | select(."@type" | endswith("BootstrapConfigDump")) | .bootstrap.node'
sub "Static listener (just the listener_http name + addr):"
curl -sS "${ADMIN}/config_dump" \
  | jq '.configs[] | select(."@type" | endswith("ListenersConfigDump")) | .static_listeners[].listener | {name, address}'
sub "Static cluster (name + type + lb_policy):"
curl -sS "${ADMIN}/config_dump" \
  | jq '.configs[] | select(."@type" | endswith("ClustersConfigDump")) | .static_clusters[].cluster | {name, type, lb_policy}'

hr "7. /runtime  — runtime overrides"
curl -sS "${ADMIN}/runtime" | jq '{entries: (.entries | keys[0:5])}'

hr "8. /logging  — current log levels per component"
echo "(GET shows current levels; POST changes them — see README.)"
curl -sS "${ADMIN}/logging" | head -8 || true

hr "9. /certs  — TLS certs in use (empty in this example, no TLS yet)"
curl -sS "${ADMIN}/certs" | jq .

hr "Done."
echo "Try also:"
echo "  curl -s ${ADMIN}/config_dump?include_eds | jq ."
echo "  curl -s ${ADMIN}/help | head -40"
echo "  make traffic   # then re-run me to see counters move"
