#!/usr/bin/env bash
#
# Generate a small CA + two server certs (one.local, two.local) for the
# downstream TLS demo. Files land in ./certs/. Idempotent: skips if the
# CA + both leaf certs already exist.
#
# This is a tutorial helper. Don't borrow it for production — at minimum
# you want stronger key sizes, OCSP stapling, proper name constraints,
# and SDS or cert-manager managing renewal.

set -euo pipefail

CERTDIR="$(cd "$(dirname "$0")" && pwd)/certs"
mkdir -p "$CERTDIR"
cd "$CERTDIR"

if [[ -f ca.crt && -f one.local.crt && -f two.local.crt ]]; then
  echo "certs/ already populated; skipping."
  exit 0
fi

quiet() { "$@" 2>/dev/null; }

# ----- 1. Root CA ------------------------------------------------------- #
quiet openssl genrsa -out ca.key 2048
quiet openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 \
  -subj "/CN=envoy-gateway-examples local CA" -out ca.crt

# ----- 2. Two leaf certs signed by the CA ------------------------------- #
for host in one.local two.local; do
  quiet openssl genrsa -out "${host}.key" 2048
  quiet openssl req -new -key "${host}.key" -subj "/CN=${host}" -out "${host}.csr"

  # SAN extension. Modern TLS libraries (curl included) ignore the CN
  # for hostname matching and look at subjectAltName instead.
  cat > "${host}.ext" <<EOF
subjectAltName = DNS:${host}
EOF

  quiet openssl x509 -req -in "${host}.csr" \
    -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "${host}.crt" -days 365 -sha256 \
    -extfile "${host}.ext"

  rm -f "${host}.csr" "${host}.ext"
done

rm -f ca.srl
echo "Generated CA + certs for one.local + two.local in $CERTDIR"
