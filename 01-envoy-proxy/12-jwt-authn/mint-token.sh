#!/usr/bin/env bash
#
# Mint a test JWT signed by keys/private.pem. All claims are overrideable
# via env vars so the verify script can produce valid / expired / wrong-
# issuer / extra-claim variants.
#
# Usage:
#   ./mint-token.sh                       # default valid token
#   EXP=100 ./mint-token.sh               # expired (1970)
#   ISS=wrong ./mint-token.sh             # wrong issuer
#   SUB=bob EXTRA='{"role":"admin"}' ./mint-token.sh
#
# Output: just the compact-serialized JWT on stdout. Nothing else.

set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f keys/private.pem ]]; then
  echo "Missing keys/private.pem — run ./gen-keys.sh first." >&2
  exit 1
fi

iss="${ISS:-envoy-demo}"
aud="${AUD:-hello}"
sub="${SUB:-alice}"
exp="${EXP:-9999999999}"           # year 2286
iat="${IAT:-$(date +%s)}"
extra="${EXTRA:-}"                 # extra claims as a JSON object
[ -z "$extra" ] && extra='{}'      # bash 3.2 doesn't like {} in `${X:-{}}`

# Build the payload by merging the base claims with $extra.
payload=$(jq -nc \
  --arg sub "$sub" --arg iss "$iss" --arg aud "$aud" \
  --argjson exp "$exp" --argjson iat "$iat" \
  --argjson extra "$extra" \
  '{sub:$sub, iss:$iss, aud:$aud, iat:$iat, exp:$exp} + $extra')

header='{"alg":"RS256","kid":"demo-key","typ":"JWT"}'

# base64url helper (RFC 7515): standard b64 minus padding, '+' -> '-',
# '/' -> '_'.
b64url() { openssl base64 -A | tr -d '=' | tr '/+' '_-'; }

h=$(printf "%s" "$header"  | b64url)
p=$(printf "%s" "$payload" | b64url)
sig=$(printf "%s.%s" "$h" "$p" \
  | openssl dgst -sha256 -sign keys/private.pem -binary \
  | b64url)

printf "%s.%s.%s\n" "$h" "$p" "$sig"
