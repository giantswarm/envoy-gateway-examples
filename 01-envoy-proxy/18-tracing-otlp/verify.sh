#!/usr/bin/env bash
set -euo pipefail

hr()   { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note() { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*"; }

# Wait for envoy + jaeger.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:9901/ready && break
  sleep 0.5
done
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:16686/ && break
  sleep 1
done

hr "1. Drive a small burst of traced traffic"
note "Sending 8 requests with varying x-user-id..."
for u in alice bob alice carol bob alice carol bob ; do
  curl -sS -o /dev/null --max-time 5 -H "x-user-id: ${u}" "http://localhost:10000/"
done
ok "8 requests sent"

# Spans batch in Jaeger; give it a moment to flush.
sleep 3

hr "2. Query Jaeger API for our service's traces"
note "Jaeger HTTP API: /api/services lists service names that have reported spans."
services=$(curl -sS http://localhost:16686/api/services | jq -r '.data[]' 2>/dev/null || true)
echo "${services}" | sed 's/^/    /'

if echo "${services}" | grep -q '^envoy-tutorial-18$'; then
  ok "Envoy is reporting as service 'envoy-tutorial-18'"
else
  warn "service not found yet — try waiting + retrying"
fi

hr "3. Fetch the most recent trace"
traces=$(curl -sS "http://localhost:16686/api/traces?service=envoy-tutorial-18&limit=1" 2>/dev/null | jq '.data | length' 2>/dev/null || echo 0)
echo "    traces returned: ${traces}"
[[ "${traces}" -ge "1" ]] && ok "Jaeger has at least one trace" || warn "no traces visible yet"

hr "4. Browse the UI"
note "Open in your browser:"
echo "    http://localhost:16686/search?service=envoy-tutorial-18"
note "Filter by tag x_user_id=alice to see Alice's requests."

hr "Done."
