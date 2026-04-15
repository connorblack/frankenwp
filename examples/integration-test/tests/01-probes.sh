#!/usr/bin/env bash
# HTTP-level probes against http://localhost:8181 (the integration stack).
#
# Verifies the *image's own* hardening: security headers, /healthz,
# rate limit zone wires correctly, no PURGE warnings in logs, opcache
# enabled. Each test prints its own pass/fail; script exits with the
# number of failures.
#
# Add a new test by writing a `run_test "name" 'shell-expression-or-grep'`
# line — the harness handles pass/fail counting + output framing.
set -uo pipefail

URL=${URL:-http://localhost:8181}
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
    # Re-run to surface the output for diagnosis.
    eval "$@" 2>&1 | sed 's/^/      /' || true
  fi
}

# Capture once so multiple greps share the same response.
HEADERS=$(curl -fsS -D - -o /dev/null "$URL/" 2>&1 || curl -sS -D - -o /dev/null "$URL/")
HEALTHZ=$(curl -sS -o /tmp/healthz.body -w '%{http_code}' "$URL/healthz")
LOGIN_HEADERS=$(curl -sS -D - -o /dev/null "$URL/wp-login.php")
ADMIN_HEADERS=$(curl -sS -D - -o /dev/null "$URL/wp-admin/")

echo "── security headers (HTTP / response) ──"
run_test "HSTS present"             "echo \"\$HEADERS\" | grep -i 'strict-transport-security:'"
run_test "X-Content-Type-Options"   "echo \"\$HEADERS\" | grep -i 'x-content-type-options: nosniff'"
run_test "X-Frame-Options"          "echo \"\$HEADERS\" | grep -i 'x-frame-options: SAMEORIGIN'"
run_test "Referrer-Policy"          "echo \"\$HEADERS\" | grep -i 'referrer-policy:'"
run_test "Permissions-Policy"       "echo \"\$HEADERS\" | grep -i 'permissions-policy:'"
run_test "Server header stripped"   "! echo \"\$HEADERS\" | grep -i '^server:'"
run_test "X-Powered-By stripped"    "! echo \"\$HEADERS\" | grep -i 'x-powered-by:'"

echo "── /healthz endpoint ──"
run_test "/healthz returns 200"     "[[ \"\$HEALTHZ\" == \"200\" ]]"
run_test "/healthz body == 'ok'"    "grep -q '^ok\$' /tmp/healthz.body"

echo "── WP routing ──"
# /wp-admin/ should redirect to /wp-login.php (302). Don't follow the
# redirect — we want to inspect the redirect response itself.
run_test "/wp-admin/ → 302"         "echo \"\$ADMIN_HEADERS\" | grep -E '^HTTP/.* 302'"
run_test "/wp-admin/ Location to /wp-login.php" \
                                    "echo \"\$ADMIN_HEADERS\" | grep -i 'location:.*wp-login.php'"
run_test "/wp-login.php → 200"      "echo \"\$LOGIN_HEADERS\" | grep -E '^HTTP/.* 200'"

echo "── compression ──"
# Send Accept-Encoding and check we get back zstd or br (preferred).
ENC_HEADERS=$(curl -sS -D - -o /dev/null --compressed -H 'Accept-Encoding: zstd, br, gzip' "$URL/")
run_test "compression negotiated (zstd or br)" \
                                    "echo \"\$ENC_HEADERS\" | grep -iE 'content-encoding: (zstd|br)'"

echo "── rate limit (POST /wp-login.php) ──"
# Fire WP_LOGIN_RATE_EVENTS+1 POSTs in quick succession; the (+1)th
# should get 429 from caddy-ratelimit.
LIMIT_RESP_FINAL=""
for i in $(seq 1 4); do
  LIMIT_RESP_FINAL=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    --data 'log=admin&pwd=wrongpass' "$URL/wp-login.php")
done
run_test "4th POST /wp-login.php → 429" "[[ \"\$LIMIT_RESP_FINAL\" == \"429\" ]]"

echo "── PHP runtime sanity (via container exec) ──"
CID=$(docker compose -p frankenwp-integration ps -q wordpress)
PHP_VERSION_OUT=$(docker exec "$CID" php -r 'echo PHP_VERSION;' 2>&1)
run_test "PHP version starts with 8.5" "[[ \"\$PHP_VERSION_OUT\" =~ ^8\\.5 ]]"

OPCACHE_STATUS=$(docker exec "$CID" php -r 'echo function_exists("opcache_get_status")?"yes":"no";')
run_test "opcache extension loaded"    "[[ \"\$OPCACHE_STATUS\" == \"yes\" ]]"

JIT_STATUS=$(docker exec "$CID" php -r 'echo ini_get("opcache.jit");')
run_test "opcache.jit env-substituted (== tracing)" "[[ \"\$JIT_STATUS\" == \"tracing\" ]]"

REDIS_LOADED=$(docker exec "$CID" php -r 'echo extension_loaded("redis")?"yes":"no";')
run_test "redis extension preinstalled" "[[ \"\$REDIS_LOADED\" == \"yes\" ]]"

GS_VERSION=$(docker exec "$CID" sh -lc 'gs --version' 2>&1)
run_test "ghostscript available for PDF thumbnails" "[[ \"\$GS_VERSION\" =~ ^10\\.|^9\\. ]]"

echo "── PHP error log scan (no PURGE warnings) ──"
# The fork's mu-plugin uses getenv() with fallbacks — should NOT emit
# the "Undefined array key" warnings the upstream version did.
PURGE_WARNS=$(docker compose -p frankenwp-integration logs wordpress 2>&1 | \
              grep -ciE 'undefined array key.*PURGE_(PATH|KEY)' || true)
run_test "0 PURGE warnings in logs"    "[[ \"\$PURGE_WARNS\" == \"0\" ]]"

echo "── WP hardening constants (DISALLOW_FILE_EDIT) ──"
# Install WP first to get a working wp-cli env. We'll reuse this
# install in 02-wp-cli.sh too. If install fails, the constant probe
# also fails — that's fine, both surface as failures.
docker exec --user www-data "$CID" wp --path=/var/www/html core install \
  --url=http://localhost:8181 \
  --title='IntegTest' \
  --admin_user='admin' \
  --admin_password='admin-test-pw' \
  --admin_email='admin@example.com' \
  --skip-email >/dev/null 2>&1 || true

HOME_TITLE=$(curl -sS "$URL/" | grep -m1 -o '<title>[^<]*</title>')
PAGE_TITLE=$(curl -sS "$URL/?page_id=2" | grep -m1 -o '<title>[^<]*</title>')
POST_TITLE=$(curl -sS "$URL/?p=1" | grep -m1 -o '<title>[^<]*</title>')
SEARCH_TITLE=$(curl -sS "$URL/?s=hello" | grep -m1 -o '<title>[^<]*</title>')
REST_QUERY_JSON=$(curl -fsS "$URL/?rest_route=/")
REST_PRETTY_JSON=$(curl -fsS "$URL/wp-json/")
UTM_HEADERS=$(curl -sS -D - -o /dev/null "$URL/?utm_source=test")
GCLID_HEADERS=$(curl -sS -D - -o /dev/null "$URL/?gclid=test")
FBCLID_HEADERS=$(curl -sS -D - -o /dev/null "$URL/?fbclid=test")
COOKIE_HEADERS=$(curl -sS -D - -o /dev/null -H 'Cookie: wordpress_logged_in_test=1' "$URL/")

echo "── query-string routing cache regression ──"
run_test "/?page_id=2 renders Sample Page title" \
                                    "echo \"\$PAGE_TITLE\" | grep -q 'Sample Page'"
run_test "/?p=1 renders Hello world title" \
                                    "echo \"\$POST_TITLE\" | grep -q 'Hello world'"
run_test "/?s=hello renders search title" \
                                    "echo \"\$SEARCH_TITLE\" | grep -q 'Search Results'"
run_test "home/page/post titles stay distinct" \
                                    "[[ \"\$HOME_TITLE\" != \"\$PAGE_TITLE\" && \"\$HOME_TITLE\" != \"\$POST_TITLE\" && \"\$PAGE_TITLE\" != \"\$POST_TITLE\" ]]"
run_test "?rest_route=/ returns JSON" \
                                    "echo \"\$REST_QUERY_JSON\" | grep -q '\"name\"'"
run_test "/wp-json/ returns JSON on plain permalinks" \
                                    "echo \"\$REST_PRETTY_JSON\" | grep -q '\"name\"'"
run_test "utm param bypasses sidekick cache" \
                                    "! echo \"\$UTM_HEADERS\" | grep -i 'x-wpeverywhere-cache:'"
run_test "gclid param bypasses sidekick cache" \
                                    "! echo \"\$GCLID_HEADERS\" | grep -i 'x-wpeverywhere-cache:'"
run_test "fbclid param bypasses sidekick cache" \
                                    "! echo \"\$FBCLID_HEADERS\" | grep -i 'x-wpeverywhere-cache:'"
run_test "logged-in cookie bypasses sidekick cache" \
                                    "! echo \"\$COOKIE_HEADERS\" | grep -i 'x-wpeverywhere-cache:'"

# New-install baseline: pretty permalinks should still keep /wp-json/
# functional after rewrite structure changes.
docker exec --user www-data "$CID" wp --path=/var/www/html rewrite structure '/%postname%/' --hard >/dev/null 2>&1
docker exec --user www-data "$CID" wp --path=/var/www/html rewrite flush --hard >/dev/null 2>&1
REST_PRETTY_JSON_AFTER=$(curl -fsS "$URL/wp-json/")
run_test "/wp-json/ returns JSON after enabling pretty permalinks" \
                                    "echo \"\$REST_PRETTY_JSON_AFTER\" | grep -q '\"name\"'"

DISALLOW_FE=$(docker exec --user www-data "$CID" wp --path=/var/www/html eval \
  'echo defined("DISALLOW_FILE_EDIT") && DISALLOW_FILE_EDIT === true ? "yes" : "no";' 2>/dev/null)
run_test "DISALLOW_FILE_EDIT defined+true" "[[ \"\$DISALLOW_FE\" == \"yes\" ]]"

DISABLE_CRON=$(docker exec --user www-data "$CID" wp --path=/var/www/html eval \
  'echo defined("DISABLE_WP_CRON") && DISABLE_WP_CRON === true ? "yes" : "no";' 2>/dev/null)
run_test "DISABLE_WP_CRON defined+true" "[[ \"\$DISABLE_CRON\" == \"yes\" ]]"

echo
echo "  $PASS passed, $FAIL failed"
exit "$FAIL"
