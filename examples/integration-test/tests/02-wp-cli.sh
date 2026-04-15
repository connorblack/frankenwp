#!/usr/bin/env bash
# WP-CLI smoke test. Assumes 01-probes.sh already ran `wp core install`,
# so this picks up an installed site and exercises the standard CLI
# operations every WP image needs to handle: theme/plugin enumeration,
# CRUD, option get/set.
#
# Each call uses --allow-root-equivalent (we're already running as
# www-data inside the container so root isn't an issue here).
set -uo pipefail

PASS=0
FAIL=0

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

CID=$(docker compose -p frankenwp-integration ps -q wordpress)
WP="docker exec --user www-data $CID wp --path=/var/www/html"

echo "── basic core checks ──"
run_test "core is-installed"       "$WP core is-installed"
run_test "core version 6.x reachable" "$WP core version | grep -E '^6\\.' "

echo "── plugin/theme listing ──"
run_test "plugin list returns rows"  "$WP plugin list --format=count | grep -E '^[0-9]+\$'"
run_test "theme list returns rows"   "$WP theme list  --format=count | grep -E '^[0-9]+\$'"

echo "── option roundtrip ──"
run_test "set site_test_key"         "$WP option update site_test_key integ-test-value"
run_test "get site_test_key matches" "[[ \$($WP option get site_test_key) == 'integ-test-value' ]]"
run_test "delete site_test_key"      "$WP option delete site_test_key"

echo "── post creation + deletion ──"
POST_ID=$($WP post create --post_title='Integ smoke' --post_status=publish --post_type=post --porcelain 2>/dev/null)
run_test "post create returns ID"    "[[ -n \"$POST_ID\" && \"$POST_ID\" =~ ^[0-9]+\$ ]]"
if [[ -n "$POST_ID" && "$POST_ID" =~ ^[0-9]+$ ]]; then
  run_test "post get by ID matches"  "$WP post get $POST_ID --field=post_title | grep -q 'Integ smoke'"
  run_test "post delete --force"     "$WP post delete $POST_ID --force"
fi

echo "── user listing ──"
run_test "user list ≥ 1 (admin)"     "[[ \$($WP user list --format=count) -ge 1 ]]"

echo "── REST API liveness ──"
# REST API works = mu-plugins didn't break wp-json routing.
run_test "GET /wp-json/ returns 200" "curl -fsS http://localhost:8181/wp-json/ | grep -q '\"name\":'"

echo
echo "  $PASS passed, $FAIL failed"
exit "$FAIL"
