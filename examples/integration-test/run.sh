#!/usr/bin/env bash
# Sellie fork integration test orchestrator.
#
# Brings up compose stack → waits for healthcheck → runs probe + WP-CLI
# tests → tears down. Returns non-zero on any test failure.
#
# Run from this directory:  ./run.sh
# Or from anywhere:          bash examples/integration-test/run.sh
#
# Environment overrides:
#   SKIP_TEARDOWN=1   leave stack up after tests (for poking around)
#   SKIP_BUILD=1      reuse cached frankenwp:integration-test image
#                     (faster iteration when only tests change)
set -euo pipefail

cd "$(dirname "$0")"

# Distinct project name so this stack doesn't collide with any other
# compose project on the operator's machine.
export COMPOSE_PROJECT_NAME=frankenwp-integration

# Helper: container ID lookup (compose service name → docker ID).
wordpress_cid() { docker compose ps -q wordpress; }

# Single point of failure summary so the operator sees what passed.
declare -a results=()
record() {
  results+=("$1")
  echo "$1"
}

# 1. Bring up
echo "── docker compose up (build: ${SKIP_BUILD:-0}) ──"
build_arg="--build"
if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  build_arg=""
fi
docker compose up -d $build_arg

# 2. Wait for healthy
echo "── waiting for healthy ──"
for i in $(seq 1 60); do
  status=$(docker inspect --format='{{.State.Health.Status}}' "$(wordpress_cid)" 2>/dev/null || echo "starting")
  if [[ "$status" == "healthy" ]]; then
    record "✓ container healthy after ${i}*5s"
    break
  fi
  if [[ "$i" == "60" ]]; then
    record "✗ container did not become healthy in 5min"
    docker compose logs wordpress | tail -50
    docker compose down -v
    exit 1
  fi
  sleep 5
done

# 3. Run probe tests
echo "── tests/01-probes.sh ──"
if bash tests/01-probes.sh; then
  record "✓ probes passed"
else
  record "✗ probes failed"
fi

# 4. Run WP-CLI smoke
echo "── tests/02-wp-cli.sh ──"
if bash tests/02-wp-cli.sh; then
  record "✓ wp-cli smoke passed"
else
  record "✗ wp-cli smoke failed"
fi

# 5. Summary
echo
echo "── summary ──"
printf '  %s\n' "${results[@]}"
fail_count=$(printf '%s\n' "${results[@]}" | grep -c '^✗' || true)

# 6. Tear down (unless asked to leave it up)
if [[ "${SKIP_TEARDOWN:-0}" != "1" ]]; then
  echo "── docker compose down -v ──"
  docker compose down -v
else
  echo "── leaving stack up (SKIP_TEARDOWN=1); 'docker compose down -v' to clean ──"
fi

exit "$fail_count"
