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

hr "1. Plain HTTP still works"
curl -sS http://localhost:10000/ | head -5 | sed 's/^/    /'

hr "2. WebSocket handshake — curl --include shows the 101 Upgrade"
note "We send the WS handshake headers manually with curl. Expect 101."
curl -sS -i --no-buffer --max-time 3 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  http://localhost:10000/.ws 2>&1 \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP|^connection|^upgrade|^sec-websocket/{print "  " $0}' \
  | head -8 || true

hr "3. End-to-end WS echo via websocat"
note "Send 'hello' over WS — expect 'hello' echoed back."
out=$(echo "hello" | websocat -1 --max-messages 1 \
  ws://localhost:10000/.ws 2>/dev/null || echo "WS_FAIL")
echo "    reply: ${out}"
if [[ "${out}" == "hello" ]]; then
  ok "WebSocket round-trip works through Envoy"
else
  warn "expected echo 'hello'; got '${out}'"
fi

hr "4. Send 3 frames, get 3 echoed back"
out=$(printf 'one\ntwo\nthree\n' | websocat -n --max-messages 3 \
  ws://localhost:10000/.ws 2>/dev/null || true)
echo "${out}" | sed 's/^/    /'

hr "Done."
