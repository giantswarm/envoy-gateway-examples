#!/usr/bin/env bash
#
# Walk through every jwt_authn outcome:
#   - no token / bad token / expired / wrong issuer / valid
# Plus claim forwarding via x-jwt-payload + x-jwt-sub / x-jwt-role.

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
status(){ curl -sS -o /dev/null -w '%{http_code}' "$@"; }

if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.
  make up                       — start the stack (also generates keys)
  docker compose logs envoy     — config rejected? jwks path wrong?
EOF
  exit 1
fi

# Mint a small zoo of tokens up front.
VALID=$(./mint-token.sh)
ADMIN_T=$(EXTRA='{"role":"admin"}' SUB=alice ./mint-token.sh)
EXPIRED=$(EXP=100 ./mint-token.sh)
WRONG_ISS=$(ISS=other-idp ./mint-token.sh)
WRONG_AUD=$(AUD=other-svc ./mint-token.sh)
GARBAGE="not.a.jwt"

# ----------------------------------------------------------------------- #
hr "1. /public — no JWT required"
note "Filter has no rule for this path; passes through."
echo "  HTTP $(status "${DATA}/public")"

# ----------------------------------------------------------------------- #
hr "2. /private — no Authorization header"
note "Filter rejects: missing token."
echo "  HTTP $(status "${DATA}/private")"

hr "3. /private — garbage token"
note "Not a valid JWT structurally."
echo "  HTTP $(status -H "Authorization: Bearer ${GARBAGE}" "${DATA}/private")"

hr "4. /private — expired token"
echo "  HTTP $(status -H "Authorization: Bearer ${EXPIRED}" "${DATA}/private")"

hr "5. /private — wrong issuer"
echo "  HTTP $(status -H "Authorization: Bearer ${WRONG_ISS}" "${DATA}/private")"

hr "6. /private — wrong audience"
echo "  HTTP $(status -H "Authorization: Bearer ${WRONG_AUD}" "${DATA}/private")"

hr "7. /private — valid token"
echo "  HTTP $(status -H "Authorization: Bearer ${VALID}" "${DATA}/private")"

# ----------------------------------------------------------------------- #
hr "8. /claims — valid token; backend sees x-jwt-payload + claim headers"
note "claim_to_headers lifts 'sub' and 'role' into x-jwt-sub / x-jwt-role."
curl -sS -H "Authorization: Bearer ${ADMIN_T}" "${DATA}/claims" \
  | jq '{
      from_,
      "x_jwt_sub":    .headers["X-Jwt-Sub"],
      "x_jwt_role":   .headers["X-Jwt-Role"],
      "x_jwt_payload_present": (.headers["X-Jwt-Payload"] != null)
    }'

note "Decoded x-jwt-payload (base64url):"
curl -sS -H "Authorization: Bearer ${ADMIN_T}" "${DATA}/claims" \
  | jq -r '.headers["X-Jwt-Payload"]' \
  | tr '_-' '/+' \
  | { read p; pad=$((4 - ${#p} % 4)); [ $pad -lt 4 ] && p="${p}$(printf '=%.0s' $(seq 1 $pad))"; echo "$p"; } \
  | base64 -d 2>/dev/null \
  | jq . | sed 's/^/    /'

# ----------------------------------------------------------------------- #
hr "9. jwt_authn stats"
note "Counters: jwt_authn.allowed / denied / no_jwt / jwks_fetch_*"
curl -sS "${ADMIN}/stats?filter=jwt_authn" | sort | head -20

hr "Done."
echo "Mint your own tokens:"
echo "  ./mint-token.sh                          # default valid"
echo "  EXP=100 ./mint-token.sh                  # expired"
echo "  EXTRA='{\"role\":\"admin\"}' ./mint-token.sh   # with extra claims"
