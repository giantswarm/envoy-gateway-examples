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

URL=http://localhost:10000

hr "1. Security response headers on every response"
note "Look for x-frame-options, x-content-type-options, strict-transport-security, referrer-policy."
curl -sS -i ${URL}/ \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP|^x-frame|^x-content|^strict-|^referrer/{print "  " $0}' \
  | tr -d '\r' | head -6

hr "2. Per-route override — /admin gets no-cache too"
curl -sS -i ${URL}/admin \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP|^cache-control|^x-frame/{print "  " $0}' \
  | tr -d '\r' | head -6

hr "3. Upstream sees the injected request header x-tutorial-step"
curl -sS ${URL}/headers | jq '.headers["X-Tutorial-Step"]' | sed 's/^/    /'

hr "4. CORS preflight — allowed origin"
note "OPTIONS from https://app.example.com — expect Access-Control-Allow-Origin echoed back."
curl -sS -i -X OPTIONS \
  -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: authorization, content-type" \
  ${URL}/ \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP|^access-control-/{print "  " $0}' \
  | tr -d '\r' | head -10

hr "5. CORS preflight — denied origin"
note "OPTIONS from https://evil.example.com — expect NO Access-Control-Allow-Origin header."
out=$(curl -sS -i -X OPTIONS \
  -H "Origin: https://evil.example.com" \
  -H "Access-Control-Request-Method: POST" ${URL}/ 2>/dev/null)
echo "${out}" | awk 'BEGIN{IGNORECASE=1} /^HTTP|^access-control-/{print "  " $0}' | tr -d '\r' | head -6
if echo "${out}" | grep -qi 'access-control-allow-origin: https://evil'; then
  warn "Envoy echoed back disallowed origin — investigate"
else
  ok "denied origin got no allow-origin header (browser would block)"
fi

hr "6. CORS preflight — wildcard subdomain via regex"
note "OPTIONS from https://acme.partners.example.com (matches the safe_regex)."
curl -sS -i -X OPTIONS \
  -H "Origin: https://acme.partners.example.com" \
  -H "Access-Control-Request-Method: GET" ${URL}/ \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP|^access-control-/{print "  " $0}' \
  | tr -d '\r' | head -4

hr "Done."
