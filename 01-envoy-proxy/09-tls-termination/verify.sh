#!/usr/bin/env bash
#
# Confirms downstream TLS termination + SNI-based filter chain selection.
# Uses curl --resolve so you don't have to touch /etc/hosts.

set -euo pipefail

ADMIN="http://localhost:9901"
HTTPS_HOST="127.0.0.1:10443"

hr()   { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note() { printf '   \033[2m%s\033[0m\n' "$*"; }
warn() { printf '   \033[33m%s\033[0m\n' "$*"; }

if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.
  make up                       — start the stack (also generates certs)
  docker compose ps             — containers running?
  docker compose logs envoy     — config rejected? cert paths wrong?
EOF
  exit 1
fi

CERTDIR="$(cd "$(dirname "$0")" && pwd)/certs"
CACERT="${CERTDIR}/ca.crt"

# ----------------------------------------------------------------------- #
hr "1. Plaintext :10000 — baseline"
note "Confirms the upstreams are reachable via plaintext HTTP first."
curl -sS http://localhost:10000/ | jq .

# ----------------------------------------------------------------------- #
hr "2. TLS to one.local — SNI=one.local, expect hello-one"
note "curl --resolve to avoid editing /etc/hosts."
curl -sS --cacert "${CACERT}" \
  --resolve "one.local:10443:127.0.0.1" \
  https://one.local:10443/ | jq .

hr "3. TLS to two.local — SNI=two.local, expect hello-two"
curl -sS --cacert "${CACERT}" \
  --resolve "two.local:10443:127.0.0.1" \
  https://two.local:10443/ | jq .

# ----------------------------------------------------------------------- #
hr "4. Inspect the actual presented cert (one.local)"
note "openssl s_client + sed pulls out subject / issuer / SANs."
openssl s_client -connect "${HTTPS_HOST}" -servername one.local \
  -showcerts < /dev/null 2>/dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
  | head -n 30 \
  | openssl x509 -noout -subject -issuer -ext subjectAltName 2>/dev/null \
  | sed 's/^/  /'

hr "5. Same handshake, but SNI=two.local — should present two.local cert"
openssl s_client -connect "${HTTPS_HOST}" -servername two.local \
  -showcerts < /dev/null 2>/dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
  | head -n 30 \
  | openssl x509 -noout -subject -issuer -ext subjectAltName 2>/dev/null \
  | sed 's/^/  /'

# ----------------------------------------------------------------------- #
hr "6. SNI mismatch — no filter chain matches, connection rejected"
note "Expect curl to fail. RESPONSE_FLAGS=NR in the access log? No — Envoy"
note "closes the TCP connection at the listener level before HCM ever runs."
if curl -sS --cacert "${CACERT}" --resolve "wrong.local:10443:127.0.0.1" \
   --max-time 3 https://wrong.local:10443/ 2>/dev/null; then
  warn "expected failure, got success — check listener config"
else
  echo "  curl failed as expected."
fi

# ----------------------------------------------------------------------- #
hr "7. Without --cacert — curl rejects unknown CA"
note "Production lesson: in dev you can pass --cacert; users need the cert"
note "to chain back to a trusted root they already have."
if curl -sS --resolve "one.local:10443:127.0.0.1" --max-time 3 \
       https://one.local:10443/ 2>/dev/null; then
  warn "expected failure, got success — system trust includes our CA?"
else
  echo "  curl failed as expected (-k would bypass; don't)."
fi

# ----------------------------------------------------------------------- #
hr "8. Admin: /certs lists what's loaded"
curl -sS "${ADMIN}/certs" | jq '.certificates[] | {ca_cert: .ca_cert[0].subject, cert_chain: [.cert_chain[]?.subject], serial: .cert_chain[0].serial_number, days_until_expiration: .cert_chain[0].days_until_expiration}'

hr "9. Admin: /listeners shows the new https listener"
curl -sS "${ADMIN}/listeners?format=json" | jq -r '.listener_statuses[].name'

hr "10. Per-chain stats (note both stat_prefix names show up)"
curl -sS "${ADMIN}/stats?filter=ingress_https" | sort | head -10

hr "Done."
echo "Useful follow-ups:"
echo "  curl -v --cacert certs/ca.crt --resolve one.local:10443:127.0.0.1 \\"
echo "    https://one.local:10443/   # verbose handshake"
echo "  openssl s_client -connect 127.0.0.1:10443 -servername one.local -alpn h2,http/1.1"
