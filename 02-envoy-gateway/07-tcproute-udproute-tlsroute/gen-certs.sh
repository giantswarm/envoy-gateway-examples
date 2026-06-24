#!/usr/bin/env bash
#
# Generate a self-signed cert for `tls.local` — used by the nginx
# backend behind the TLSRoute (passthrough). Distinct from example
# 05's CA-signed certs because here Envoy doesn't see the cert at
# all; only the backend pod presents it.

set -euo pipefail

CERTDIR="$(cd "$(dirname "$0")" && pwd)/certs"
mkdir -p "$CERTDIR"
cd "$CERTDIR"

if [[ -f tls.local.crt && -f tls.local.key ]]; then
  echo "certs/ already populated; skipping."
  exit 0
fi

quiet() { "$@" 2>/dev/null; }

quiet openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout tls.local.key -out tls.local.crt \
  -days 365 \
  -subj "/CN=tls.local" \
  -addext "subjectAltName=DNS:tls.local"

echo "Generated self-signed cert for tls.local in $CERTDIR"
