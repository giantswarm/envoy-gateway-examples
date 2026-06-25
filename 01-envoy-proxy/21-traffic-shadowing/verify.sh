#!/usr/bin/env bash
set -euo pipefail

hr()   { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note() { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*"; }

for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:9901/ready && break
  sleep 0.5
done

hr "1. Drive 5 requests — client should ONLY see the primary"
note "Each response's from_ field should say 'primary', NEVER 'shadow'."
for i in 1 2 3 4 5 ; do
  curl -sS "http://localhost:10000/" | jq -r '.from_' | sed 's/^/    /'
done

hr "2. The shadow backend received the same 5 requests"
note "Look at shadow's container logs — should show 5 access entries."
sleep 1  # let logs flush
shadow_hits=$( (docker compose logs shadow --tail=200 2>/dev/null \
                | grep -cE 'GET / HTTP') 2>/dev/null || echo 0 )
[[ -z "${shadow_hits}" ]] && shadow_hits=0
echo "    shadow access-log entries for GET /: ${shadow_hits}"
if [[ "${shadow_hits}" -ge 5 ]]; then
  ok "shadow received the teed traffic"
else
  warn "expected ≥ 5 hits on shadow; got ${shadow_hits}"
fi

hr "3. Shadow sees a different :authority"
note "Envoy appends '-shadow' to the Host header on mirrored requests"
note "so the upstream can distinguish primary from mirror."
docker compose logs shadow --tail=200 2>/dev/null \
  | grep -E 'Host:|host:' | tail -3 | sed 's/^/    /' || true

hr "4. Mirror failures don't affect the client"
note "Stop the shadow backend, then drive 5 more requests."
docker compose stop shadow >/dev/null 2>&1 || true
sleep 1
ok="0"
for i in 1 2 3 4 5 ; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:10000/")
  [[ "${code}" == "200" ]] && ok=$((ok+1))
done
echo "    primary returned 200 for ${ok}/5 requests with shadow DOWN"
if [[ "${ok}" == "5" ]]; then
  ok "client unaffected by shadow outage — the tee is truly fire-and-forget"
else
  warn "expected 5/5 200s with shadow down; got ${ok}/5"
fi

# Restore shadow so make down works cleanly.
docker compose start shadow >/dev/null 2>&1 || true

hr "5. Cluster stats — confirm the tee landed (envoy.cluster.shadow.*)"
curl -sS http://localhost:9901/stats?filter=cluster.shadow \
  | grep -E 'upstream_rq_total|upstream_rq_2xx' | head -5 | sed 's/^/    /' || true

hr "Done."
