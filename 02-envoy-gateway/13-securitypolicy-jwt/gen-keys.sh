#!/usr/bin/env bash
#
# Generate an RSA keypair + a JWKS (JSON Web Key Set) for the JWT
# SecurityPolicy demo. Idempotent — skips if keys/ is already
# populated.
#
# The JWKS is what Envoy uses to verify signatures. In this example
# it's inlined into the SecurityPolicy via `localJWKS.inline`.
# Production usually uses `remoteJWKS.uri` pointing at the issuer's
# /.well-known/jwks.json (see exercise 5).

set -euo pipefail
cd "$(dirname "$0")"
mkdir -p keys

if [[ -f keys/private.pem && -f keys/jwks.json ]]; then
  echo "keys/ already populated; skipping."
  exit 0
fi

# --- 1. RSA keypair ----------------------------------------------------- #
openssl genrsa -out keys/private.pem 2048 2>/dev/null
openssl rsa -in keys/private.pem -pubout -out keys/public.pem 2>/dev/null

# --- 2. JWKS ------------------------------------------------------------ #
# openssl gives us the RSA modulus as `Modulus=ABCDEF...` in hex. JWKS
# needs the modulus as big-endian raw bytes, base64url-encoded.
# `e=65537` (0x010001) is base64url("AQAB") and is what `openssl
# genrsa` always produces, so we hard-code it.
modulus_hex=$(openssl rsa -in keys/private.pem -modulus -noout | cut -d= -f2)
n_b64=$(printf "%s" "$modulus_hex" \
  | xxd -r -p \
  | openssl base64 -A \
  | tr -d '=' | tr '/+' '_-')

cat > keys/jwks.json <<EOF
{
  "keys": [
    {
      "kty": "RSA",
      "kid": "tutorial-key",
      "use": "sig",
      "alg": "RS256",
      "n": "${n_b64}",
      "e": "AQAB"
    }
  ]
}
EOF

echo "Generated keys/ + jwks.json (kid=tutorial-key)"
