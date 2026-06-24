#!/usr/bin/env bash
#
# Self-signed cert for `apps.local`. Goes into a Secret in the
# `demo` namespace — the Gateway lives in `apps`, so this is the
# cross-namespace reference our ReferenceGrant authorizes.

set -euo pipefail

CERTDIR="$(cd "$(dirname "$0")" && pwd)/certs"
mkdir -p "$CERTDIR"
cd "$CERTDIR"

if [[ -f apps.local.crt && -f apps.local.key ]]; then
  echo "certs/ already populated; skipping."
  exit 0
fi

quiet() { "$@" 2>/dev/null; }

# Self-signed; for educational purposes only. See example 05 for the
# CA-signed pattern + cert-manager sidebar.
quiet openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout apps.local.key -out apps.local.crt \
  -days 365 \
  -subj "/CN=apps.local" \
  -addext "subjectAltName=DNS:apps.local"

echo "Generated self-signed cert for apps.local in $CERTDIR"
