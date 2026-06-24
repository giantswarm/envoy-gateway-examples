#!/usr/bin/env bash
#
# Generate a small CA + a leaf cert whose SAN matches the Service's
# in-cluster FQDN. That's what Envoy will validate when it connects
# upstream — see backendtlspolicy.yaml's validation.hostname.

set -euo pipefail

CERTDIR="$(cd "$(dirname "$0")" && pwd)/certs"
mkdir -p "$CERTDIR"
cd "$CERTDIR"

# Keep this aligned with the Service name + namespace in the manifests/.
HOST=secure-backend.tls-upstream-demo.svc.cluster.local

if [[ -f ca.crt && -f backend.crt && -f backend.key ]]; then
  echo "certs/ already populated; skipping."
  exit 0
fi

quiet() { "$@" 2>/dev/null; }

# 1. CA (we mount its public cert into a ConfigMap so Envoy can trust it).
quiet openssl genrsa -out ca.key 2048
quiet openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 \
  -subj "/CN=envoy-gateway-examples backend CA" -out ca.crt

# 2. Leaf cert for the backend pod. SAN matches the in-cluster FQDN.
quiet openssl genrsa -out backend.key 2048
quiet openssl req -new -key backend.key -subj "/CN=${HOST}" -out backend.csr

cat > backend.ext <<EOF
subjectAltName = DNS:${HOST}, DNS:secure-backend, DNS:secure-backend.tls-upstream-demo.svc
EOF

quiet openssl x509 -req -in backend.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out backend.crt -days 365 -sha256 \
  -extfile backend.ext

rm -f backend.csr backend.ext ca.srl
echo "Generated CA + backend cert for ${HOST} in $CERTDIR"
