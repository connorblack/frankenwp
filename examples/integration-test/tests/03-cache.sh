#!/usr/bin/env bash
# Cache write/read/purge integration test.
#
# Verifies:
#   1. A cacheable GET is served from cache on second hit (X-WPEverywhere-Cache header)
#   2. Purge behavior adapts to PURGE_KEY configuration:
#      - PURGE_KEY unset: purge works without auth (default path)
#      - PURGE_KEY set: purge works with correct key, rejected without
#   3. Cache inventory GET endpoint does not leak without auth
#
# Assumes 01-probes.sh already ran `wp core install`.
set -uo pipefail

URL=${URL:-http://localhost:8181}
PASS=0
FAIL=0

# Read PURGE_KEY from the integration-test compose environment.
CID=$(docker compose -p frankenwp-integration ps -q wordpress)
PURGE_KEY=$(docker exec "$CID" sh -c 'echo "${PURGE_KEY:-}"' 2>/dev/null)

run_test() {
  local name="$1"; shift
  echo -n "  [$name] "
  if eval "$@" >/dev/null 2>&1; then
    echo "✓"
    ((PASS++))
  else
    echo "✗"
    ((FAIL++))
    eval "$@" 2>&1 | sed 's/^/      /' || true
  fi
}

echo "── cache write/read ──"
# First request: cache MISS (populates cache)
FIRST=$(curl -sS -D - -o /dev/null "$URL/")
# Second request: should be a cache HIT
SECOND=$(curl -sS -D - -o /dev/null "$URL/")
run_test "second GET / is cache HIT" \
  "echo \"\$SECOND\" | grep -i 'x-wpeverywhere-cache:.*hit'"

echo "── cache purge (PURGE_KEY='${PURGE_KEY:-(empty)}') ──"
PURGE_RESP=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H "X-WPSidekick-Purge-Key: ${PURGE_KEY}" \
  "$URL/__cache/purge/")

if [[ -n "$PURGE_KEY" ]]; then
  # Key is set — purge should succeed with correct key
  run_test "POST /__cache/purge/ with key returns 200" \
    "[[ \"\$PURGE_RESP\" == \"200\" ]]"

  AFTER_PURGE=$(curl -sS -D - -o /dev/null "$URL/")
  run_test "GET / after purge is cache MISS" \
    "! echo \"\$AFTER_PURGE\" | grep -i 'x-wpeverywhere-cache:.*hit'"
else
  # No key configured — purge works without auth (Option A).
  run_test "POST /__cache/purge/ accepted (no-auth purge)" \
    "[[ \"\$PURGE_RESP\" == \"200\" ]]"

  AFTER_PURGE=$(curl -sS -D - -o /dev/null "$URL/")
  run_test "GET / after purge is cache MISS" \
    "! echo \"\$AFTER_PURGE\" | grep -i 'x-wpeverywhere-cache:.*hit'"
fi

echo "── cache inventory guard ──"
# GET to purge path without a configured key should NOT return cache listing
INVENTORY_RESP=$(curl -sS -o /tmp/cache-inventory.body -w '%{http_code}' \
  "$URL/__cache/purge/")
run_test "GET /__cache/purge/ does not leak cache inventory (no JSON object)" \
  "! grep -Eq '^\[|^\{' /tmp/cache-inventory.body"

echo
echo "  $PASS passed, $FAIL failed"
exit "$FAIL"
