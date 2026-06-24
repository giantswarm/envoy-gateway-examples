#!/usr/bin/env bash
#
# Generate an RSA keypair + a JWKS (JSON Web Key Set) for the JWT authn
# demo. Idempotent — skips if keys/ is already populated.
#
# Why we build the JWKS by hand: openssl can produce PEM, but not JWK.
# The RSA public key is just (n, exponent). Envoy's jwt_authn filter
# reads the JWKS to validate signatures; the matching private key
# (kept in keys/private.pem) is what `mint-token.sh` uses to sign.
#
# Tutorial-grade. Real systems fetch the JWKS from the issuer's
# /.well-known endpoint via `remote_jwks` (see exercise 5).

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
# Modulus comes out of openssl as `Modulus=ABCDEF...` in hex. We need
# big-endian raw bytes, base64url-encoded. The exponent is the standard
# RSA `e=65537` (0x010001), which encodes to "AQAB" — that's true for
# every cert openssl genrsa produces, so we just hard-code it.
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
      "kid": "demo-key",
      "use": "sig",
      "alg": "RS256",
      "n": "${n_b64}",
      "e": "AQAB"
    }
  ]
}
EOF

echo "Generated keys/ + jwks.json (kid=demo-key)"
