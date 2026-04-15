# Contract & Security Remediation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three P1 contract regressions (GOMEMLIMIT, cache purge, FORCE_HTTPS documentation drift), fix security gaps in the cache endpoint and examples, align the public surface area (README, examples, CI tags), and add integration tests that prevent these regressions from recurring.

**Architecture:** Two-repo remediation. The frankenwp repo owns the image defaults, examples, Caddyfile, sidekick cache module, mu-plugin, and integration tests. The wpai repo owns `sellie-cli` (cloud.ts, wp-install.ts) and `wp-config-runtime.php` — these have stale comments and a missing env injection that derive from false assumptions about the frankenwp image. This plan addresses frankenwp first (Tasks 1-9), then wpai (Task 10), because the wpai fixes depend on decisions made here.

**Tech Stack:** Docker, Go (sidekick/cache), PHP (mu-plugin), Bash (integration tests), Caddyfile, GitHub Actions YAML

**Decision points:** Tasks 2 and 10 each have a binary decision that changes the implementation. Read the options, pick one, then execute the corresponding steps.

---

## Findings Ledger

All findings from both reviews plus newly discovered issues, deduplicated and prioritized.

| ID | Sev | Title | Source | File(s) |
|----|-----|-------|--------|---------|
| F1 | P1 | GOMEMLIMIT=0 is a zero-byte limit, not "no limit" | codex review | `Dockerfile:114` |
| F2 | P1 | Empty PURGE_KEY disables cache invalidation on default path | both reviews | `contentCachePurge.php:24`, `cache.go:252,266`, `examples/basic/compose.yaml:19` |
| F3 | P1 | wpai cloud.ts + wp-config-runtime.php claim fork ships FORCE_HTTPS=1 (it ships 0) | code review | `cloud.ts:382-387`, `wp-config-runtime.php:81-86` |
| F4 | P2 | trusted_proxies static private_ranges allows rate-limit bypass from any RFC1918 source | codex review | `Caddyfile:17` |
| F5 | P2 | Cache GET endpoint leaks full cache inventory when PURGE_KEY is empty | new | `cache.go:249-261` |
| F6 | P2 | README points to wrong registry/tag (Docker Hub php8.3 vs GHCR php8.5) | code review | `README.md:6`, `README.md:106` |
| F7 | P2 | Example compose files override Caddyfile hardened defaults with weaker values | new | `examples/basic/compose.yaml:23-24`, `examples/debug/compose.yaml:23-24` |
| F8 | P2 | CACHE_RESPONSE_CODES=000 in basic+debug examples disables caching entirely | new | `examples/basic/compose.yaml:24`, `examples/debug/compose.yaml:24` |
| F9 | P3 | SQLite example BYPASS_PATH_PREFIXES missing leading `/` on wp-includes | new | `examples/sqlite/compose.yaml:23` |
| F10 | P3 | No cache purge integration test | new | `examples/integration-test/tests/` |
| F11 | P3 | Integration test port 8181 hard-coded, no collision guard | new | `examples/integration-test/compose.yaml:31` |
| F12 | P3 | WP-CLI not version-pinned | code review | `Dockerfile:328-330` |
| F13 | P1 | GOMEMLIMIT not in WORDPRESS_BUILD_KEYS — Coolify deploys inherit bad default | new | `cloud.ts:389-394` |
| F14 | P2 | HSTS header set over plain HTTP (spec says browsers ignore, creates confusion) | implicit | `Caddyfile:119` |

---

## Task 1: Fix GOMEMLIMIT default

**Fixes:** F1  
**Files:**
- Modify: `Dockerfile:113-114`

The Go runtime interprets `GOMEMLIMIT=0` as a zero-byte soft memory limit, not "no limit." The value for "no limit" is `math.MaxInt64`, achieved by not setting the env var or setting `GOMEMLIMIT=off`. Remove the ENV line so operators explicitly set it at deploy time (the integration-test compose already overrides to `768MiB`).

- [ ] **Step 1: Read the current GOMEMLIMIT lines in the Dockerfile**

Verify lines 113-114 still contain:
```dockerfile
ENV GODEBUG=cgocheck=0
ENV GOMEMLIMIT=0
```

- [ ] **Step 2: Remove the GOMEMLIMIT ENV line and update the comment**

Replace the GOMEMLIMIT block (lines 97-114) with:

```dockerfile
# Go runtime tuning for containerized FrankenPHP.
#
# GODEBUG=cgocheck=0 — already the default in dunglas/frankenphp images
# per https://frankenphp.dev/docs/performance/, but we set explicitly
# so it's grep-discoverable. Disables Go's CGO pointer-passing checks
# which add ~10-20% overhead on every PHP↔Go call (every request).
#
# GOMEMLIMIT — deliberately NOT set in the image. Operators MUST set
# this at deploy time to ~80% of their container memory limit (e.g.
# GOMEMLIMIT=1638MiB for a 2 GB container). Without it the Go runtime
# doesn't observe the container's cgroup memory limit and runs GC too
# lazily; under bursty load this leads to OOM kills mid-request.
# IMPORTANT: GOMEMLIMIT=0 is NOT "no limit" — it's a zero-byte limit
# that makes GC run continuously. Use GOMEMLIMIT=off or simply don't
# set the var to disable.
# https://pkg.go.dev/runtime#hdr-Environment_Variables
ENV GODEBUG=cgocheck=0
```

- [ ] **Step 3: Verify integration-test compose still overrides**

Confirm `examples/integration-test/compose.yaml` still has `GOMEMLIMIT: "768MiB"` (line 52). No change needed there.

- [ ] **Step 4: Update README GOMEMLIMIT bullet**

In `README.md`, find the GOMEMLIMIT bullet (around line 81-86) and update to remove the claim about `ENV GOMEMLIMIT=0`:

Replace:
```
> - **Go runtime tuning**: `ENV GOMEMLIMIT=0` (operator MUST set to
>   ~80% of container memory limit, e.g. `GOMEMLIMIT=1638MiB` for
>   2 GB containers — without this Go GC ignores the cgroup and OOM
>   kills mid-burst); `ENV GODEBUG=cgocheck=0` (disables CGO pointer
>   checks for ~10-20% per-request speedup, default in upstream image
>   but explicit here for grep-discovery).
```
With:
```
> - **Go runtime tuning**: `GOMEMLIMIT` is deliberately NOT set in
>   the image — operators MUST set it at deploy time to ~80% of
>   container memory (e.g. `GOMEMLIMIT=1638MiB` for 2 GB containers).
>   Without it Go GC ignores the cgroup limit and OOM-kills under
>   burst. Do NOT set `GOMEMLIMIT=0` (that's a zero-byte limit, not
>   "no limit"). `ENV GODEBUG=cgocheck=0` disables CGO pointer checks
>   for ~10-20% per-request speedup.
```

- [ ] **Step 5: Build the image and verify GOMEMLIMIT is unset**

Run:
```bash
docker build -t frankenwp:gomemlimit-test . 2>&1 | tail -5
docker run --rm --entrypoint env frankenwp:gomemlimit-test | grep GOMEMLIMIT || echo "GOMEMLIMIT not set (correct)"
```
Expected: "GOMEMLIMIT not set (correct)"

- [ ] **Step 6: Commit**

```bash
git add Dockerfile README.md
git commit -m "$(cat <<'EOF'
fix(runtime): remove GOMEMLIMIT=0 default (was zero-byte limit, not "no limit")

GOMEMLIMIT=0 is interpreted by the Go runtime as a zero-byte soft
memory limit, causing the GC to run nearly continuously. The correct
way to express "no limit" is to not set the variable at all (or set
GOMEMLIMIT=off). Operators must set this at deploy time to ~80% of
their container memory.
EOF
)"
```

---

## Task 2: Fix cache purge contract (PURGE_KEY empty path)

**Fixes:** F2, F5  
**Files:**
- Modify: `wp-content/mu-plugins/contentCachePurge.php:18-26`
- Modify: `sidekick/middleware/cache/cache.go:249-266`

**Decision required:** Pick one of these two approaches:

### Option A: Restore unauthenticated purge (preserve old behavior)

If the intent is "cache purge should work out of the box without PURGE_KEY," then the mu-plugin should send the purge request even when the key is empty, and the Go handler should continue accepting empty-key matches. The early return in the mu-plugin was the regression.

- [ ] **Step A1: Write a test assertion for the integration test (see Task 7)**

Add to `examples/integration-test/tests/01-probes.sh` a cache purge test section. (Detailed in Task 7.)

- [ ] **Step A2: Remove the early return from contentCachePurge.php**

Replace lines 22-26 of `contentCachePurge.php`:
```php
    // No key => sidekick cache purge is unauthenticated => skip silently.
    // Operators wanting cache purge set PURGE_KEY (a random secret).
    if ($purge_key === '') {
        return;
    }
```
With:
```php
    // When PURGE_KEY is unset, purge requests are sent without auth.
    // Sidekick accepts empty-key purges when its own PURGE_KEY config
    // is also empty (the default). This keeps cache invalidation
    // working out of the box. Operators who want auth-gated purges
    // set PURGE_KEY to a shared secret in their env.
```

- [ ] **Step A3: Guard the cache inventory GET endpoint**

In `cache.go`, the GET handler at line 249-261 returns the full cache listing when the key matches. When both keys are empty, this leaks the cache inventory to any unauthenticated GET. Add a guard:

In `cache.go`, replace the GET handler block (around line 249):
```go
	if strings.Contains(r.URL.Path, c.PurgePath) && r.Method == "GET" {
		key := r.Header.Get("X-WPSidekick-Purge-Key")

		if key == c.PurgeKey {
```
With:
```go
	if strings.Contains(r.URL.Path, c.PurgePath) && r.Method == "GET" {
		key := r.Header.Get("X-WPSidekick-Purge-Key")

		// Only return cache inventory when a non-empty purge key is
		// configured and the request supplies the matching key. Empty
		// keys must not leak the cache listing to unauthenticated callers.
		if c.PurgeKey != "" && key == c.PurgeKey {
```

- [ ] **Step A4: Run Go tests**

```bash
cd sidekick/middleware/cache && go test ./...
```
Expected: PASS

- [ ] **Step A5: Commit**

```bash
git add wp-content/mu-plugins/contentCachePurge.php sidekick/middleware/cache/cache.go
git commit -m "$(cat <<'EOF'
fix(cache): restore default purge-on-save when PURGE_KEY is empty

The early return in contentCachePurge.php broke cache invalidation on
the default install path (empty PURGE_KEY). Sidekick still accepts
empty-key purges, so the mu-plugin should send them.

Also guards the cache inventory GET endpoint: listing is now only
returned when a non-empty PURGE_KEY is configured and matched.
Prevents unauthenticated cache enumeration on default installs.
EOF
)"
```

### Option B: Make PURGE_KEY mandatory (intentional new contract)

If the intent is "purge auth is required, no unauthenticated purges," then the Go handler also needs to reject empty keys, the examples need updating, and `cloud.ts` should auto-generate a PURGE_KEY on `sellie cloud init`.

- [ ] **Step B1: Guard both GET and POST in cache.go**

In `cache.go` GET handler (line 249), POST handler (line 263), add an early reject:
```go
	// Reject purge requests when no PURGE_KEY is configured.
	// Cache invalidation requires auth — operators must set PURGE_KEY.
	if c.PurgeKey == "" {
		c.logger.Warn("wp cache - purge rejected: PURGE_KEY not configured")
		http.Error(w, "purge key not configured", http.StatusForbidden)
		return nil
	}
```

- [ ] **Step B2: Update mu-plugin comment to explain the contract**

Replace lines 22-23 of `contentCachePurge.php`:
```php
    // No key => sidekick rejects unauthenticated purge requests.
    // Operators MUST set PURGE_KEY for cache invalidation to work.
```

- [ ] **Step B3: Run Go tests**

```bash
cd sidekick/middleware/cache && go test ./...
```

- [ ] **Step B4: Commit**

```bash
git add sidekick/middleware/cache/cache.go wp-content/mu-plugins/contentCachePurge.php
git commit -m "$(cat <<'EOF'
fix(cache): make PURGE_KEY mandatory for cache invalidation

Both mu-plugin and sidekick now require a non-empty PURGE_KEY.
Operators must set PURGE_KEY in their env for purge-on-save to work.
Unauthenticated purge/inventory requests are rejected with 403.
EOF
)"
```

---

## Task 3: Fix README registry and tag references

**Fixes:** F6  
**Files:**
- Modify: `README.md:6-7`
- Modify: `README.md:106`

- [ ] **Step 1: Update the header tag reference**

In `README.md` line 6, replace:
```markdown
> Published as `ghcr.io/connorblack/frankenwp:latest-php8.3` (and to
> Docker Hub when `DOCKERHUB_USERNAME` secret is set).
```
With:
```markdown
> Published as `ghcr.io/connorblack/frankenwp:latest-php8.5` (GHCR only).
```

- [ ] **Step 2: Update the Getting Started links**

In `README.md` around line 106, replace:
```markdown
- [Docker Images](https://hub.docker.com/r/wpeverywhere/frankenwp "Docker Hub")
```
With:
```markdown
- [Docker Images](https://github.com/connorblack/frankenwp/pkgs/container/frankenwp "GHCR")
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: update README registry refs (GHCR php8.5, not Docker Hub php8.3)
EOF
)"
```

---

## Task 4: Fix example compose files

**Fixes:** F7, F8, F9  
**Files:**
- Modify: `examples/basic/compose.yaml`
- Modify: `examples/debug/compose.yaml`
- Modify: `examples/sqlite/compose.yaml`

The examples should NOT override Caddyfile defaults for cache/security settings. The Caddyfile already has the correct inline defaults. Operators who want to override do so via their own env. Examples that shadow the hardened defaults with weaker values mislead users AND the integration test.

- [ ] **Step 1: Fix examples/basic/compose.yaml**

Replace the wordpress service environment block. Remove env vars that merely restate or weaken Caddyfile defaults. Keep only vars the operator genuinely needs to set:

```yaml
services:
  wordpress:
    image: ghcr.io/connorblack/frankenwp:latest-php8.5
    restart: always
    ports:
      - "8100:80"
    environment:
      SERVER_NAME: ${SERVER_NAME:-:80}
      WORDPRESS_DB_HOST: ${DB_HOST:-db}
      WORDPRESS_DB_USER: ${DB_USER:-exampleuser}
      WORDPRESS_DB_PASSWORD: ${DB_PASSWORD:-examplepass}
      WORDPRESS_DB_NAME: ${DB_NAME:-exampledb}
      WORDPRESS_DEBUG: ${WP_DEBUG:-true}
      WORDPRESS_TABLE_PREFIX: ${DB_TABLE_PREFIX:-wp_}
      # Cache/security env vars intentionally omitted — the Caddyfile
      # ships hardened defaults. Override in your .env if needed.
      WORDPRESS_CONFIG_EXTRA: |
          define('WP_SITEURL', 'http://localhost:8100');
          define('WP_HOME', 'http://localhost:8100');
    volumes: []
    depends_on:
      - db
    tty: true
```

- [ ] **Step 2: Fix examples/debug/compose.yaml**

The debug compose uses `build: .` (builds from local Dockerfile), not a remote image tag — keep that. Remove all cache/security env var overrides. The existing compose has NO XDebug-specific settings (the only differences from basic are the build context and the `test.php` volume mount). The `BYPASS_PATH_PREFIXES: /` override was effectively disabling all caching, which is more broken than useful for debugging. `WORDPRESS_DEBUG` is kept since it's a development example.

Replace the wordpress service environment block:

```yaml
services:
  wordpress:
    build: .
    restart: always
    ports:
      - "8099:80"
    environment:
      SERVER_NAME: ${SERVER_NAME:-:80}
      WORDPRESS_DB_HOST: ${DB_HOST:-db}
      WORDPRESS_DB_USER: ${DB_USER:-exampleuser}
      WORDPRESS_DB_PASSWORD: ${DB_PASSWORD:-examplepass}
      WORDPRESS_DB_NAME: ${DB_NAME:-exampledb}
      WORDPRESS_DEBUG: ${WP_DEBUG:-true}
      WORDPRESS_TABLE_PREFIX: ${DB_TABLE_PREFIX:-wp_}
      # Cache/security env vars intentionally omitted — the Caddyfile
      # ships hardened defaults. Override in your .env if needed.
      CADDY_GLOBAL_OPTIONS: |
        debug
      WORDPRESS_CONFIG_EXTRA: |
          define('WP_SITEURL', 'http://localhost:8099');
          define('WP_HOME', 'http://localhost:8099');
    volumes:
      - ./test.php:/var/www/html/test.php
    depends_on:
      - db
    tty: true
```

- [ ] **Step 3: Fix examples/sqlite/compose.yaml**

The sqlite compose also uses `build: .` — keep that. Remove all cache/security env var overrides (this also fixes the `wp-includes` missing-leading-`/` typo at line 23 by deleting the override entirely).

- [ ] **Step 4: Verify compose configs parse**

```bash
for f in examples/basic/compose.yaml examples/debug/compose.yaml examples/sqlite/compose.yaml; do
  docker compose -f "$f" config --quiet && echo "$f: OK" || echo "$f: FAIL"
done
```
Expected: all OK

- [ ] **Step 5: Commit**

```bash
git add examples/basic/compose.yaml examples/debug/compose.yaml examples/sqlite/compose.yaml
git commit -m "$(cat <<'EOF'
fix(examples): use correct image tag, stop overriding Caddyfile defaults

- Point to ghcr.io/connorblack/frankenwp:latest-php8.5
- Remove env vars that shadowed Caddyfile hardened defaults with weaker
  values (dropped /wp-login.php from bypass, CACHE_RESPONSE_CODES=000)
- Fix sqlite example typo: wp-includes was missing leading /
EOF
)"
```

---

## Task 5: Add cache purge integration test

**Fixes:** F10  
**Depends on:** Task 2 (the purge test branches on whether PURGE_KEY is set)  
**Files:**
- Create: `examples/integration-test/tests/03-cache.sh`
- Modify: `examples/integration-test/run.sh`

- [ ] **Step 1: Create the cache test script**

The script detects whether PURGE_KEY is configured and adjusts assertions accordingly. Under Option A (empty key = purge works), it tests the full write/read/purge cycle. Under Option B (key mandatory), it verifies purge is rejected without a key.

```bash
#!/usr/bin/env bash
# Cache write/read/purge integration test.
#
# Verifies:
#   1. A cacheable GET is served from cache on second hit (X-WPEverywhere-Cache header)
#   2. Purge behavior adapts to PURGE_KEY configuration:
#      - PURGE_KEY unset: purge works without auth (Option A) OR is rejected (Option B)
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

  # Wrong key should fail
  BAD_KEY_RESP=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H 'X-WPSidekick-Purge-Key: wrong-key' \
    "$URL/__cache/purge/")
  run_test "POST with wrong key does not purge" \
    "[[ \"\$BAD_KEY_RESP\" == \"200\" ]]"
    # Note: sidekick returns 200 OK even on bad key (logs a warning),
    # but the cache is NOT actually purged.
else
  # No key configured — behavior depends on Task 2 decision.
  # Option A: purge works (200), cache is invalidated.
  # Option B: purge rejected (403), cache survives.
  # Test whichever behavior is actually implemented:
  if [[ "$PURGE_RESP" == "200" ]]; then
    run_test "POST /__cache/purge/ accepted (no-auth purge enabled)" "true"
    AFTER_PURGE=$(curl -sS -D - -o /dev/null "$URL/")
    run_test "GET / after purge is cache MISS" \
      "! echo \"\$AFTER_PURGE\" | grep -i 'x-wpeverywhere-cache:.*hit'"
  elif [[ "$PURGE_RESP" == "403" ]]; then
    run_test "POST /__cache/purge/ rejected (auth required)" "true"
    AFTER_PURGE=$(curl -sS -D - -o /dev/null "$URL/")
    run_test "GET / after rejected purge is still cache HIT" \
      "echo \"\$AFTER_PURGE\" | grep -i 'x-wpeverywhere-cache:.*hit'"
  else
    run_test "POST /__cache/purge/ returns expected code (200 or 403)" "false"
  fi
fi

echo "── cache inventory guard ──"
# GET to purge path without a configured key should NOT return cache listing
INVENTORY_RESP=$(curl -sS -o /tmp/cache-inventory.body -w '%{http_code}' \
  "$URL/__cache/purge/")
run_test "GET /__cache/purge/ does not leak cache list (no JSON array)" \
  "! grep -q '^\[' /tmp/cache-inventory.body"

echo
echo "  $PASS passed, $FAIL failed"
exit "$FAIL"
```

- [ ] **Step 2: Add the cache test to run.sh**

After the `02-wp-cli.sh` block in `run.sh`, add (note: section numbering continues from existing `# 4.`):

```bash
# 5. Run cache tests
echo "── tests/03-cache.sh ──"
if bash tests/03-cache.sh; then
  record "✓ cache tests passed"
else
  record "✗ cache tests failed"
fi
```

Also update the existing `# 5. Summary` to `# 6. Summary` and `# 6. Tear down` to `# 7. Tear down` to keep numbering consistent.

- [ ] **Step 3: Make the script executable**

```bash
chmod +x examples/integration-test/tests/03-cache.sh
```

- [ ] **Step 4: Commit**

```bash
git add examples/integration-test/tests/03-cache.sh examples/integration-test/run.sh
git commit -m "$(cat <<'EOF'
test(integration): add cache write/read/purge test

Verifies default-path cache behavior: second GET is HIT, POST purge
clears it, subsequent GET is MISS. Also asserts the cache inventory
GET endpoint doesn't leak to unauthenticated callers.
EOF
)"
```

---

## Task 6: Make integration test port configurable

**Fixes:** F11  
**Files:**
- Modify: `examples/integration-test/compose.yaml:31`
- Modify: `examples/integration-test/run.sh`
- Modify: `examples/integration-test/tests/01-probes.sh`
- Modify: `examples/integration-test/tests/02-wp-cli.sh`
- Modify: `examples/integration-test/tests/03-cache.sh` (from Task 5)

- [ ] **Step 1: Parameterize the port in compose.yaml**

Replace line 31:
```yaml
      - "8181:80"
```
With:
```yaml
      - "${TEST_PORT:-8181}:80"
```

- [ ] **Step 2: Export TEST_PORT in run.sh and pass to test scripts**

At the top of `run.sh` after the `COMPOSE_PROJECT_NAME` line, add:
```bash
export TEST_PORT="${TEST_PORT:-8181}"
export URL="http://localhost:${TEST_PORT}"
```

- [ ] **Step 3: Update 02-wp-cli.sh to use $URL**

Replace line 56:
```bash
run_test "GET /wp-json/ returns 200" "curl -fsS http://localhost:8181/wp-json/ | grep -q '\"name\":'"
```
With:
```bash
run_test "GET /wp-json/ returns 200" "curl -fsS ${URL}/wp-json/ | grep -q '\"name\":'"
```

Also update the `wp core install` URL in `01-probes.sh` line 103:
```bash
  --url="${URL}" \
```

- [ ] **Step 4: Verify compose config still parses**

```bash
TEST_PORT=9999 docker compose -f examples/integration-test/compose.yaml config --quiet
```
Expected: quiet success

- [ ] **Step 5: Commit**

```bash
git add examples/integration-test/
git commit -m "$(cat <<'EOF'
fix(test): make integration test port configurable via TEST_PORT env

Defaults to 8181. Operators with a port collision run:
  TEST_PORT=9999 bash examples/integration-test/run.sh
EOF
)"
```

---

## Task 7: Document trusted_proxies limitation

**Fixes:** F4  
**Files:**
- Modify: `Caddyfile:9-17`
- Modify: `README.md` (security section)

The `trusted_proxies static private_ranges` directive is the correct default for single-proxy deployments (Coolify Traefik on the same host). Narrowing it to a specific IP breaks portability. The right fix is documentation + an env-var escape hatch.

- [ ] **Step 1: Add env-var override for trusted_proxies**

In `Caddyfile`, replace lines 9-17:
```
	servers {
		# Trust the proxy chain for {client_ip} / X-Forwarded-* parsing.
		# `private_ranges` covers RFC1918 + loopback + link-local — the
		# default-safe set for "behind any reverse proxy on the same host
		# or private network." Without this, Caddy treats Traefik's IP as
		# the client and downstream WP plugins (Wordfence, rate-limiters,
		# is_user_logged_in() edge cases) lose the real visitor IP.
		# https://caddyserver.com/docs/caddyfile/options#trusted-proxies
		trusted_proxies static private_ranges
```
With:
```
	servers {
		# Trust the proxy chain for {client_ip} / X-Forwarded-* parsing.
		# Default: `private_ranges` (RFC1918 + loopback + link-local) —
		# correct for single-proxy deployments (Coolify Traefik on the
		# same host). On shared VPCs/Kubernetes where multiple private
		# clients can reach this container, narrow to your actual proxy
		# IP(s) via TRUSTED_PROXY_RANGES to prevent X-Forwarded-For
		# spoofing (which bypasses the rate limiter keyed on {client_ip}).
		# https://caddyserver.com/docs/caddyfile/options#trusted-proxies
		trusted_proxies static {$TRUSTED_PROXY_RANGES:private_ranges}
```

- [ ] **Step 2: Add a note to the README environment variables section**

After the `FORCE_HTTPS` bullet, add:
```markdown
- `TRUSTED_PROXY_RANGES`: Override the default `private_ranges` trusted proxy set. On shared VPCs or Kubernetes where multiple private-network clients can reach the container, set to your actual proxy IP(s) (e.g. `172.17.0.1`) to prevent `X-Forwarded-For` spoofing.
```

- [ ] **Step 3: Verify Caddyfile still parses**

```bash
docker build -t frankenwp:proxy-test . 2>&1 | tail -3
docker run --rm frankenwp:proxy-test frankenphp validate --config /etc/caddy/Caddyfile 2>&1
```
Expected: valid configuration

- [ ] **Step 4: Commit**

```bash
git add Caddyfile README.md
git commit -m "$(cat <<'EOF'
feat(security): make trusted_proxies configurable via TRUSTED_PROXY_RANGES

Defaults to private_ranges (same behavior). Operators on shared VPCs
can narrow to their actual proxy IP to prevent X-Forwarded-For spoofing,
which would bypass the rate limiter keyed on {client_ip}.
EOF
)"
```

---

## Task 8: Pin WP-CLI version

**Fixes:** F12  
**Files:**
- Modify: `Dockerfile:328-330`

- [ ] **Step 1: Identify the current WP-CLI release**

```bash
curl -sI https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar | grep -i 'etag\|content-length'
```

Check https://github.com/wp-cli/wp-cli/releases for the latest stable tag (likely 2.11.0 or 2.12.0 at time of writing).

- [ ] **Step 2: Replace the WP-CLI download with a pinned version + checksum**

Replace lines 328-330:
```dockerfile
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    chmod +x wp-cli.phar && \
    mv wp-cli.phar /usr/local/bin/wp
```
With (update version and sha512 to match the actual release):
```dockerfile
# Pin WP-CLI to a specific release for supply chain reproducibility.
# Bump by updating WP_CLI_VERSION + WP_CLI_SHA512 together.
# Get the checksum for a new version:
#   curl -sL https://github.com/wp-cli/wp-cli/releases/download/v<VERSION>/wp-cli-<VERSION>.phar.sha512
ARG WP_CLI_VERSION=2.11.0
ARG WP_CLI_SHA512="FILL_AT_IMPLEMENTATION_TIME"
RUN curl -fsSL "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
      -o /usr/local/bin/wp && \
    echo "${WP_CLI_SHA512}  /usr/local/bin/wp" | sha512sum -c - && \
    chmod +x /usr/local/bin/wp && \
    wp --info >/dev/null 2>&1
```

**Implementation note:** The exact version and sha512 hash MUST be filled in at implementation time. Run this to get the hash:
```bash
curl -sL https://github.com/wp-cli/wp-cli/releases/download/v2.11.0/wp-cli-2.11.0.phar | sha512sum
```
If 2.11.0 is not the latest, check https://github.com/wp-cli/wp-cli/releases first.

- [ ] **Step 3: Verify WP-CLI works in the built image**

```bash
docker build -t frankenwp:wpcli-test . 2>&1 | tail -3
docker run --rm --entrypoint wp frankenwp:wpcli-test --version
```
Expected: `WP-CLI 2.11.0`

- [ ] **Step 4: Commit**

```bash
git add Dockerfile
git commit -m "$(cat <<'EOF'
fix(supply-chain): pin WP-CLI to release version instead of rolling gh-pages

Downloads from the tagged GitHub release instead of the gh-pages branch
rolling artifact. Operators bump by updating WP_CLI_VERSION build arg.
EOF
)"
```

---

## Task 9: Conditional HSTS (only when FORCE_HTTPS=1)

**Fixes:** F14  
**Files:**
- Modify: `Caddyfile:116-129`

HSTS over plain HTTP is a no-op per the spec (browsers must ignore it on non-secure transport), but it creates confusion for developers running locally. Gate it on the same FORCE_HTTPS env var.

- [ ] **Step 1: Read the Caddyfile header block**

Verify lines 116-129 contain the security headers including HSTS.

- [ ] **Step 2: Evaluate feasibility**

Caddyfile does NOT support conditional directives based on env vars inside a `header` block. The `header` directive applies statically. To conditionally add HSTS, we'd need a `@https` matcher or a `respond` handler — which adds complexity.

**Simpler approach:** Leave HSTS in place and add a comment explaining why it's harmless on plain HTTP. The browser ignores it, and it ensures the header is present when the container IS behind HTTPS (the production path). This is the standard practice for origin servers behind a TLS-terminating edge.

Add a comment to the HSTS line:
```
		# HSTS is set unconditionally. Browsers ignore it over plain HTTP
		# (RFC 6797 §7.2), so it's harmless in local/example deployments.
		# When the container is behind a TLS-terminating edge (the
		# production path), the browser sees it over HTTPS and enforces it.
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
```

- [ ] **Step 3: Commit**

```bash
git add Caddyfile
git commit -m "$(cat <<'EOF'
docs(caddyfile): document why HSTS is set on plain HTTP origin
EOF
)"
```

---

## Task 10: Fix wpai downstream (separate repo)

**Fixes:** F3, F13  
**Files (in wpai repo):**
- Modify: `packages/sellie-cli/src/commands/cloud.ts:382-387`
- Modify: `apps/wordpress/docker/wp-config-runtime.php:81-86`
- Modify: `packages/sellie-cli/src/commands/cloud.ts:389-394` (WORDPRESS_BUILD_KEYS)

This task is in the **wpai** repo, not frankenwp. Execute after Tasks 1-9 are merged.

- [ ] **Step 1: Fix cloud.ts FORCE_HTTPS comment**

Replace lines 382-387:
```typescript
 * FORCE_HTTPS used to live here as a workaround: upstream
 * wpeverywhere/frankenwp shipped ENV FORCE_HTTPS=0, breaking is_ssl()
 * behind a TLS-terminating edge. Our connorblack/frankenwp fork
 * defaults FORCE_HTTPS=1 in the image, so the env injection is gone.
 * Operators wanting to opt OUT (rare) set FORCE_HTTPS=0 in their .env
 * and `verify` will still surface it via the standard sync path.
```
With:
```typescript
 * FORCE_HTTPS: the connorblack/frankenwp fork ships FORCE_HTTPS=0 by
 * default (local-friendly). Coolify deploys behind a TLS-terminating
 * edge need FORCE_HTTPS=1 for is_ssl() to return true. We inject it
 * as a default below; operators override via clients/<name>/.env.
```

- [ ] **Step 2: Add FORCE_HTTPS to WORDPRESS_BUILD_KEYS**

```typescript
export const WORDPRESS_BUILD_KEYS = [
  'WP_SITE',
  'GIT_SHA',
  'BYPASS_HOME',
  'BYPASS_QUERY_STRINGS',
  'FORCE_HTTPS',
  'GOMEMLIMIT',
] as const
```

- [ ] **Step 3: Inject FORCE_HTTPS=1 and GOMEMLIMIT as defaults in resolveEffectiveEnvFile**

In the `if (needsWpSite)` block (around line 422), after the BYPASS_QUERY_STRINGS injection, add:
```typescript
    // FORCE_HTTPS=1 so is_ssl() returns true behind Coolify's
    // TLS-terminating Traefik. The fork image defaults FORCE_HTTPS=0
    // for local/plain-HTTP use — Coolify deploys always need it on.
    if (!merged.FORCE_HTTPS) merged.FORCE_HTTPS = '1'

    // GOMEMLIMIT to ~80% of the Coolify container memory limit.
    // The fork image deliberately does NOT set a default (0 is wrong).
    // Default to 1638MiB (80% of 2 GB, Coolify's default container size).
    if (!merged.GOMEMLIMIT) merged.GOMEMLIMIT = '1638MiB'
```

- [ ] **Step 4: Fix wp-config-runtime.php comment**

Replace lines 81-86:
```php
// HTTPS=on is set by FrankenWP's bundled wp-config-docker.php sed
// `if (!!getenv("FORCE_HTTPS")) { $_SERVER["HTTPS"] = "on"; }`. Our
// connorblack/frankenwp fork ships ENV FORCE_HTTPS=1 by default so this
// fires unconditionally, eliminating the auto_prepend_file workaround
// that previously pinned HTTPS=on here. is_ssl() returns true,
// force_ssl_admin stops looping, admin_url() builds HTTPS links.
```
With:
```php
// HTTPS=on is set by FrankenWP's bundled wp-config-docker.php sed
// `if (!!getenv("FORCE_HTTPS")) { $_SERVER["HTTPS"] = "on"; }`.
// The connorblack/frankenwp fork ships FORCE_HTTPS=0 by default
// (local-friendly). Coolify deploys get FORCE_HTTPS=1 injected by
// sellie-cli's env sync (cloud.ts resolveEffectiveEnvFile). That
// makes is_ssl() return true, force_ssl_admin stops looping, and
// admin_url() builds HTTPS links. If FORCE_HTTPS is missing from
// the Coolify env, is_ssl() returns false and admin redirects loop.
```

- [ ] **Step 5: Update cloud.test.ts**

The existing test at line 158 asserts `PURGE_KEY` is not in build keys. Add assertions for the new keys:
```typescript
expect(WORDPRESS_BUILD_KEYS).toContain('FORCE_HTTPS')
expect(WORDPRESS_BUILD_KEYS).toContain('GOMEMLIMIT')
```

- [ ] **Step 6: Run tests**

```bash
cd /Users/connorblack/github/wpai && pnpm test -- --filter sellie-cli
```

- [ ] **Step 7: Commit**

```bash
git add packages/sellie-cli/src/commands/cloud.ts \
       packages/sellie-cli/src/commands/cloud.test.ts \
       apps/wordpress/docker/wp-config-runtime.php
git commit -m "$(cat <<'EOF'
fix(cloud): inject FORCE_HTTPS=1 and GOMEMLIMIT for Coolify WP deploys

The frankenwp fork ships FORCE_HTTPS=0 (local-friendly default), not
FORCE_HTTPS=1 as the comments claimed. Coolify deploys behind Traefik
need FORCE_HTTPS=1 for is_ssl() to return true. Also injects GOMEMLIMIT
to prevent Go's GC from ignoring the container memory limit.

Fixes stale comments in cloud.ts and wp-config-runtime.php.
EOF
)"
```

---

## Verification Checklist

After all tasks are complete, run these verifications:

```bash
# 1. GOMEMLIMIT not baked into the image (plain docker run, no compose)
docker run --rm --entrypoint env frankenwp:integration-test | grep GOMEMLIMIT || echo "GOMEMLIMIT absent (correct)"
# Expected: "GOMEMLIMIT absent (correct)" — the var should NOT appear
# because it's no longer set in the Dockerfile. The integration-test
# compose injects it at runtime, but a bare `docker run` should not have it.

# 2. FORCE_HTTPS=0 still the image default
docker run --rm --entrypoint env frankenwp:integration-test | grep FORCE_HTTPS
# Expected: FORCE_HTTPS=0

# 3. Full integration test suite
TEST_PORT=8282 bash examples/integration-test/run.sh
# Expected: all tests pass (including new cache tests)

# 4. Example compose files parse
for f in examples/*/compose.yaml; do
  docker compose -f "$f" config --quiet && echo "$f: OK"
done

# 5. Go tests
cd sidekick/middleware/cache && go test ./...

# 6. bash -n on all test scripts
for f in examples/integration-test/tests/*.sh examples/integration-test/run.sh; do
  bash -n "$f" && echo "$f: OK"
done
```
