#!/usr/bin/env bash
#
# Walk through every ext-authz outcome. Eight steps; ~5s total.

set -euo pipefail

DATA="http://localhost:10000"
ADMIN="http://localhost:9901"

hr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
note()  { printf '   \033[2m%s\033[0m\n' "$*"; }
status(){ curl -sS -o /dev/null -w '%{http_code}' "$@"; }

if ! curl -sSf -o /dev/null --max-time 2 "${ADMIN}/ready"; then
  cat <<EOF >&2
ERROR: Envoy admin endpoint at ${ADMIN} is not reachable.
  make up                       — start the stack
  docker compose ps             — authz container up?
  docker compose logs authz     — Python crashed?
EOF
  exit 1
fi

# Wait briefly for authz to be ready (Flask dev server can take a beat).
for _ in 1 2 3 4 5; do
  curl -sSf -o /dev/null --max-time 2 "${DATA}/public" && break || sleep 1
done

# ----------------------------------------------------------------------- #
hr "1. /public — ext-authz disabled per-route, no service call"
echo "  HTTP $(status "${DATA}/public")"

hr "2. /protected — missing x-user-id, authz denies"
echo "  HTTP $(status "${DATA}/protected")"

hr "3. /protected — x-user-id: alice, authz allows"
echo "  HTTP $(status -H 'x-user-id: alice' "${DATA}/protected")"

hr "4. /admin — no role, authz denies (403)"
echo "  HTTP $(status -H 'x-user-id: alice' "${DATA}/admin")"

hr "5. /admin — x-user-role: admin, authz allows"
echo "  HTTP $(status -H 'x-user-id: alice' -H 'x-user-role: admin' "${DATA}/admin")"

# ----------------------------------------------------------------------- #
hr "6. Backend receives the x-authz-decision header"
note "authz returned an allow + extra header; Envoy forwarded it upstream."
curl -sS -H 'x-user-id: alice' -H 'x-user-role: admin' "${DATA}/admin" \
  | jq '{
      from_,
      "x_authz_decision": .headers["X-Authz-Decision"],
      "x_user_id":        .headers["X-User-Id"],
      "x_user_role":      .headers["X-User-Role"]
    }'

# ----------------------------------------------------------------------- #
hr "7. ext_authz stats"
curl -sS "${ADMIN}/stats?filter=ext_authz" | sort | head -10

# ----------------------------------------------------------------------- #
hr "8. failure_mode_allow demo — what happens when authz is unreachable?"
note "Stopping the authz container; expect requests to be DENIED."
docker compose stop authz >/dev/null 2>&1
sleep 2
echo "  /protected with authz down -> HTTP $(status -H 'x-user-id: alice' "${DATA}/protected")"
note "Bringing authz back up..."
docker compose start authz >/dev/null 2>&1
# Give it a moment to come back.
for _ in 1 2 3 4 5; do
  status_code=$(status -H 'x-user-id: alice' "${DATA}/protected")
  [ "$status_code" = "200" ] && break
  sleep 1
done
echo "  /protected after recovery   -> HTTP ${status_code}"

hr "Done."
echo "Useful follow-ups:"
echo "  docker compose logs authz                      # decisions per request"
echo "  curl -s '${ADMIN}/clusters?cluster=authz_cluster'  # endpoint health"
echo "  curl -s '${ADMIN}/stats?filter=ext_authz'"
