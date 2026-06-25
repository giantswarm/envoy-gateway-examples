#!/usr/bin/env bash
set -euo pipefail

hr()   { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note() { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*"; }

# Wait for envoy /ready.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sSf -o /dev/null --max-time 1 http://localhost:9901/ready && break
  sleep 0.5
done

hr "1. Backend sees the header Lua injected (x-lua-greeting)"
note "Send x-from: alice → expect x-lua-greeting: hello-alice-from-lua at the upstream."
curl -sS -H "x-from: alice" http://localhost:10000/headers \
  | jq '{from_, lua_greeting: .headers["X-Lua-Greeting"]}' | sed 's/^/    /'

hr "2. Client sees the header Lua stamped on the response (x-served-by-lua)"
note "Look at response headers — x-served-by-lua should be 'yes'."
curl -sS -i http://localhost:10000/ \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP|^x-served-by-lua/{print "  " $0}' \
  | tr -d '\r' | head -4

hr "3. Lua's logInfo lands in Envoy stdout"
note "Last 3 'lua:' lines from envoy logs:"
docker compose logs envoy --tail=200 2>/dev/null | grep 'lua:' | tail -3 | sed 's/^/    /' || \
  warn "no lua: log lines found yet — try traffic + 'make logs'"

hr "Done."
