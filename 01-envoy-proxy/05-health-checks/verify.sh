#!/usr/bin/env bash
#
# Demonstrates active health checks + outlier detection.
# Will stop and restart `hello-c` mid-script to simulate a backend
# failure. Takes ~30 seconds (active HC needs interval * threshold to
# decide).

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
wait_s(){ printf '   \033[2msleep %ss…\033[0m\n' "$1"; sleep "$1"; }

if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.
  make up                       — start the stack
  docker compose ps             — containers running?
  docker compose logs envoy     — config rejected?
EOF
  exit 1
fi

# Health-status one-liner per endpoint.
endpoint_status() {
  curl -sS "${ADMIN}/clusters?format=json" \
    | jq -r '
        .cluster_statuses[]
        | select(.name=="helloworld_cluster")
        | .host_statuses[]
        | "  \(.hostname // .address.socket_address.address):\(.address.socket_address.port_value)  \(.health_status // {})"
      '
}

distribution() {
  local n=$1
  for _ in $(seq 1 "$n"); do
    curl -sS -o /tmp/hc.body -w '%{http_code}\n' "${DATA}/" >/tmp/hc.status
    code=$(cat /tmp/hc.status)
    if [[ "$code" == "200" ]]; then
      jq -r .from_ /tmp/hc.body
    else
      echo "HTTP_${code}"
    fi
  done | sort | uniq -c
}

# ----------------------------------------------------------------------- #
hr "1. Initial endpoint health"
note "Give active HC one or two intervals to do its first probe (~5s)."
wait_s 6
endpoint_status

hr "2. Distribution across the cluster (30 requests)"
note "hello-bad should not appear — active HC ejected it for returning 500."
distribution 30

# ----------------------------------------------------------------------- #
hr "3. Stop hello-c — active HC should mark it unhealthy after ~4s"
docker compose stop hello-c
wait_s 8
endpoint_status

hr "4. Distribution while hello-c is down (30 requests)"
note "Only hello-a and hello-b should serve."
distribution 30

# ----------------------------------------------------------------------- #
hr "5. Restart hello-c — active HC should restore it after 2 successful probes"
docker compose start hello-c
wait_s 8
endpoint_status

hr "6. Distribution after recovery (30 requests)"
distribution 30

# ----------------------------------------------------------------------- #
hr "7. Cluster-level health stats"
note "Counters for active HC and outlier ejections live under cluster.<name>.*"
curl -sS "${ADMIN}/stats?filter=cluster.helloworld_cluster.(health_check|outlier)" || true

hr "Done."
echo "Inspect per-endpoint detail at any time with:"
echo "  curl -s '${ADMIN}/clusters?cluster=helloworld_cluster'"
