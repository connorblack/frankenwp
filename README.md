# WordPress + FrankenPHP Docker Image — sellie fork

> **This is a fork** of [StephenMiracle/frankenwp](https://github.com/StephenMiracle/frankenwp)
> (last upstream activity June 2024). Maintained at
> [connorblack/frankenwp](https://github.com/connorblack/frankenwp).
> Published as `ghcr.io/connorblack/frankenwp:latest-php8.3` (and to
> Docker Hub when `DOCKERHUB_USERNAME` secret is set).
>
> **What this fork changes vs. upstream:**
> - **PHP 8.5 default** (was 8.3). Pinned to `dunglas/frankenphp:1-php8.5`
>   because the upstream `latest-php8.5` rolling tag doesn't exist on
>   Docker Hub even though FrankenPHP ships PHP 8.5 in their numbered
>   releases. Override with `--build-arg PHP_VERSION=8.3` if your
>   plugin set isn't 8.5-ready (WP officially says 8.5 is "beta
>   support" — most plugins work, some don't).
> - **FrankenPHP HEAD source** instead of the `1.12.2` source baked
>   into the builder image. v1.12.2's `caddy/php-server.go` calls
>   `caddycmd.LoadConfig` expecting 3 returns; Caddy v2.11+ returns 4.
>   `xcaddy build` against the bundled source fails with "assignment
>   mismatch". Pin via `--build-arg FRANKENPHP_COMMIT=<sha>` —
>   defaults to commit `dbc09d2` (2026-04-09, fixes the call site).
>   Bump to `v1.12.3` once that release ships.
> - `ENV FORCE_HTTPS=1` (was `0`) — `is_ssl()` works behind a TLS-terminating
>   edge by default. Opt out with explicit `FORCE_HTTPS=0`.
> - `wp-content/mu-plugins/contentCachePurge.php` — uses `getenv()` with
>   fallbacks instead of `$_SERVER[]` direct reads. No more "Undefined
>   array key" warnings on every request when the cache purge env vars
>   are unset; skips the purge call entirely when no `PURGE_KEY` is
>   configured.
> - GitHub Actions workflow publishes to GHCR (zero-config via
>   `GITHUB_TOKEN`) plus optional Docker Hub mirror, on a native
>   arm64 build matrix (`ubuntu-latest` + `ubuntu-24.04-arm`)
>   instead of QEMU-emulated arm64 — ~10× faster steady-state CI.
> - Dropped `php-8_2.yaml` workflow (PHP 8.2 is EOL).
> - **Caddyfile hardening**: `trusted_proxies static private_ranges`
>   so `{client_ip}` is the real visitor IP behind a reverse proxy;
>   `servers { timeouts { read_header 10s; read_body 60s; write 5m;
>   idle 5m } }` to bound stalled requests; security-header set
>   (HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy,
>   Permissions-Policy, `-Server`, `-X-Powered-By`); `request_body
>   max_size 512MB` matched to `php.ini upload_max_filesize` so the
>   limits agree; `/healthz` endpoint that bypasses PHP entirely
>   (Coolify/Traefik-friendly liveness probe); `wp_cache
>   bypass_path_prefixes` extended to include `/wp-login.php` +
>   `/xmlrpc.php` (upstream missed both — stale auth nonce risk).
> - **Brute-force protection**: `caddy-ratelimit` plugin baked in
>   with a default zone of 5 attempts per client IP per 5 minutes
>   against `POST /wp-login.php` and `POST /xmlrpc.php`. Tunable
>   via `WP_LOGIN_RATE_EVENTS` + `WP_LOGIN_RATE_WINDOW`.
> - **opcache + JIT tuning**: `opcache.memory_consumption=256`
>   (was 128, exhausted on real plugin sets), `interned_strings_buffer=16`,
>   `max_accelerated_files=10000` (was 4000), `revalidate_freq=60`
>   (was 2, ~30× fewer stat() syscalls/req). JIT enabled in tracing
>   mode by default (`OPCACHE_JIT=tracing`, buffer 64M); env-gated.
> - **`php.ini` production defaults**: `memory_limit=256M`,
>   `max_execution_time=120`, `realpath_cache_size=4M`,
>   `realpath_cache_ttl=600`, `max_input_vars=5000`. Override via
>   any 99-*.ini file dropped into `$PHP_INI_DIR/conf.d/`.
> - **`redis` PHP extension** preinstalled. Drop in
>   [rhubarbgroup/redis-cache](https://wordpress.org/plugins/redis-cache/)
>   and wire `WP_REDIS_HOST` for object cache without rebuilding.
> - **`caddy-cache-handler` (Souin)** baked in alongside sidekick.
>   Not enabled in the baseline Caddyfile — sidekick remains the
>   default cache. Souin is available for operators that want to
>   migrate (more featureful, distributed); enable via
>   `CADDY_GLOBAL_OPTIONS` + `CADDY_SERVER_EXTRA_DIRECTIVES`.
> - **WP hardening constants** baked into `wp-config-docker.php`
>   via env vars: `DISALLOW_FILE_EDIT=1` (block dashboard
>   plugin/theme code editor — WP's own hardening recommendation),
>   `DISABLE_WP_CRON=1` (when paired with an external scheduler).
>   String-or-boolean constants like `WP_AUTO_UPDATE_CORE` go via
>   `WORDPRESS_CONFIG_EXTRA` per upstream pattern.
> - **Go runtime tuning**: `ENV GOMEMLIMIT=0` (operator MUST set to
>   ~80% of container memory limit, e.g. `GOMEMLIMIT=1638MiB` for
>   2 GB containers — without this Go GC ignores the cgroup and OOM
>   kills mid-burst); `ENV GODEBUG=cgocheck=0` (disables CGO pointer
>   checks for ~10-20% per-request speedup, default in upstream image
>   but explicit here for grep-discovery).
> - **CVE scanning**: GHA workflow runs `aquasecurity/trivy-action`
>   non-blockingly after each multi-arch publish; results land in
>   GitHub Security tab as SARIF.
> - **Image hygiene**: dropped upstream's redundant pre-install of
>   dev headers (libonig/libxml2/libcurl/libssl/libzip/libjpeg/
>   libwebp/libmemcached) — `install-php-extensions` already manages
>   its own build deps and cleans them up. Also dropped `ghostscript`
>   (CVE magnet — Imagick's PDF→raster delegate; not used by typical
>   WP image processing) and `git`/`unzip` (build-time only).
> - **Integration test**: `examples/integration-test/` — Docker
>   Compose stack (image + MariaDB) with a probe runner that
>   verifies security headers, /healthz, rate-limit behavior,
>   opcache+JIT live state, WP-CLI smoke, REST API liveness.
>   Run: `bash examples/integration-test/run.sh`.

An enterprise-grade WordPress image built for scale. It uses the new FrankenPHP server bundled with Caddy. Lightning-fast server side caching Caddy module.

## Getting Started

- [Docker Images](https://hub.docker.com/r/wpeverywhere/frankenwp "Docker Hub")
- [Slack](https://join.slack.com/t/wpeverywhere/shared_invite/zt-2k88x3jtv-dpJHRYJ2IDT9PNQpO96zxQ "Slack")
- [Website](https://wpeverywhere.com)

### Examples

- [Standard environment with MariaDB & Docker Compose](./examples/basic/compose.yaml)
- [Debug with XDebug & Docker Compose](./examples/debug/compose.yaml)
- [SQLite with Docker Compose](./examples/sqlite/compose.yaml)

## Whats Included

### Services

- [WordPress](https://hub.docker.com/_/wordpress "WordPress Docker Image")
- [FrankenPHP](https://hub.docker.com/r/dunglas/frankenphp "FrankenPHP Docker Image")
- [Caddy](https://caddyserver.com/ "Caddy Server")

### Caching

- opcache
- Internal server sidekick

### Environment Variables

#### FrankenPHP

- `SERVER_NAME`: change the addresses on which to listen, the provided hostnames will also be used for the generated TLS certificate
- `CADDY_GLOBAL_OPTIONS`: inject global options (debug most common)
- `FRANKENPHP_CONFIG`: inject config under the frankenphp directive

#### Sidekick Cache

- `CACHE_LOC`: Where to store cache. Defaults to /var/www/html/wp-content/cache
- `CACHE_RESPONSE_CODES`: Which status codes to cache. Defaults to 200,404,405
- `BYPASS_PATH_PREFIX`: Which path prefixes to not cache. Defaults to /wp-admin,/wp-json
- `BYPASS_HOME`: Whether to skip caching home. Defaults to false.
- `PURGE_KEY`: Create a purge key that must be validated on purge requests. Helps to prevent malicious intent. No default.
- `PURGE_PATH`: Create a custom route for the cache purge API path. Defaults to /\_\_cache/purge.
- `TTL`: Defines how long objects should be stored in cache. Defaults to 6000.

#### Wordpress

- `DB_NAME`: The WordPress database name.
- `DB_USER`: The WordPress database user.
- `DB_PASSWORD`: The WordPress database password.
- `DB_HOST`: The WordPress database host.
- `DB_TABLE_PREFIX`: The WordPress database table prefix.
- `WP_DEBUG`: Turns on WordPress Debug.
- `FORCE_HTTPS`: Tells WordPress to use https on requests. This is beneficial behind load balancer. Defaults to true.
- `WORDPRESS_CONFIG_EXTRA`: use this for adding WP_HOME, WP_SITEURL, etc

## Questions

### Why Not Just Use Standard WordPress Images?

The standard WordPress images are a good starting point and can handle many use cases, but require significant modification to scale. You also don't get FrankenPHP app server. Instead, you need to choose Apache or PHP-FPM. We use the WordPress base image but extend it with FrankenPHP & Caddy.

### Why FrankenPHP?

FrankenPHP is built on Caddy, a modern web server built in Go. It is secure & performs well when scaling becomes important. It also allows us to take advantage of built-in mature concurrency through goroutines into a single Docker image. high performance in a single lean image.

**[Check out FrankenPHP Here](https://frankenphp.dev/ "FrankenPHP")**

### Why is Non-Root User Important?

It is good practice to avoid using root users in your Docker images for security purposes. If a questionable individual gets access into your running Docker container with root account then they could have access to the cluster and all the resources it manages. This could be problematic. On the other hand, by creating a user specific to the Docker image, narrows the threat to only the image itself. It is also important to note that the base WordPress images also create non-root users by default.

### What are the Changes from Base FrankenPHP?

This custom Caddy build also includes an internal project named sidekick. It provides lightning fast cache that can be distributed among many containers. The default cache uses the local wp-content/cache directory but can use many cache services.

### How to use when behind load balancer or proxy?

_tldr: Use a port (ie :80, :8095, etc) for SERVER_NAME env variable._

Working in cloud environments like AWS can be tricky because your traffic is going through a load balancer or some proxy. This means your server name is not what you think your server name is. Your domain hits a proxy dns entry that then hits your application. The application doesn't know your domain. It knows the proxied name. This may seem strange, but it's actually a well established strong architecture pattern.

What about SSL cert? Use `SERVER_NAME=mydomain.com, :80`
Caddy, the underlying application server is flexible enough for multiple entries. Separate multiple values with a comma. It will still request certificate.

## Using in Real Projects? Join the Chat

You can join our Slack chat to ask questions or connect directly. [Connect on Slack](https://join.slack.com/t/wpeverywhere/shared_invite/zt-2k88x3jtv-dpJHRYJ2IDT9PNQpO96zxQ)
