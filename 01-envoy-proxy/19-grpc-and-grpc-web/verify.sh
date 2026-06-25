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

hr "1. Native gRPC (HTTP/2) on :10001 — grpcurl as a 'server' client"
grpcurl -plaintext localhost:10001 list | sed 's/^/    /'

note "Unary call to hello.HelloService/SayHello:"
grpcurl -plaintext \
  -d '{"greeting": "envoy"}' \
  localhost:10001 hello.HelloService/SayHello | sed 's/^/    /'

note "Server-streaming RPC — LotsOfReplies returns multiple frames:"
grpcurl -plaintext \
  -d '{"greeting": "stream"}' \
  localhost:10001 hello.HelloService/LotsOfReplies 2>/dev/null \
  | jq -r '.reply // empty' | head -5 | sed 's/^/    /' || true

hr "2. gRPC-Web (HTTP/1.1) on :10000 — what a browser sends"
note "Envoy's grpc_web filter translates HTTP/1.1 framing to HTTP/2 upstream."
note "Use grpcurl's --use-reflection over -import-path… or simulate the wire format:"
note "(grpcurl over plaintext to :10000 works because grpc_web also accepts native gRPC)"
grpcurl -plaintext localhost:10000 hello.HelloService/SayHello \
  -d '{"greeting": "browser"}' | sed 's/^/    /' || warn "call failed"

hr "3. Inspect the gRPC-Web protocol headers"
note "POST a base64-encoded gRPC frame as a real browser would —"
note "look for grpc-web framing in the response headers."
curl -sS -i -X POST \
  -H "Content-Type: application/grpc-web-text" \
  -H "Accept: application/grpc-web-text" \
  --data-binary @<(printf '\0\0\0\0\x07\n\x05world' | base64) \
  http://localhost:10000/hello.HelloService/SayHello \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP|^content-type|^grpc-/{print "  " $0}' \
  | tr -d '\r' | head -8

hr "4. CORS preflight from a browser origin"
curl -sS -i -X OPTIONS \
  -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type, x-grpc-web" \
  http://localhost:10000/hello.HelloService/SayHello \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP|^access-control-/{print "  " $0}' \
  | tr -d '\r' | head -8

hr "Done."
echo "Useful follow-ups:"
echo "  grpcurl -plaintext localhost:10001 describe hello.HelloService"
echo "  grpcurl -plaintext -d '{\"f_string\":\"x\",\"f_int32\":42}' localhost:10001 grpcbin.GRPCBin/DummyUnary"
