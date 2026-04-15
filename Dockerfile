ARG WORDPRESS_VERSION=latest
# Sellie fork: PHP 8.5 default (was 8.3). FrankenPHP's `latest-php8.5`
# rolling tag doesn't exist on Docker Hub even though they ship 8.5
# in their numbered releases — we pin to the `1-*-php8.5` track to
# get PHP 8.5 while still tracking 1.x patch updates.
ARG PHP_VERSION=8.5
ARG FRANKENPHP_TAG=1
ARG USER=www-data



FROM dunglas/frankenphp:${FRANKENPHP_TAG}-builder-php${PHP_VERSION} AS builder

# Copy xcaddy in the builder image
COPY --from=caddy:builder /usr/bin/xcaddy /usr/bin/xcaddy

# Override the FrankenPHP source pre-baked into the builder image
# (currently v1.12.2) with HEAD. The bundled v1.12.2 caddy/php-server.go
# calls caddycmd.LoadConfig expecting 3 returns; Caddy v2.11+ returns 4,
# so xcaddy build fails with "assignment mismatch: 3 variables but
# caddycmd.LoadConfig returns 4 values". Fixed in upstream HEAD (commit
# dbc09d2, 2026-04-09) but not yet released — pin to that SHA for
# reproducibility, or override at build time once v1.12.3 ships:
#   --build-arg FRANKENPHP_COMMIT=v1.12.3
ARG FRANKENPHP_COMMIT=dbc09d2282b548f8f23e278c1adfb648560359a5
WORKDIR /go/src/app
RUN find /go/src/app -mindepth 1 -delete && \
    git clone --no-checkout --depth 200 https://github.com/php/frankenphp.git . && \
    git checkout ${FRANKENPHP_COMMIT} && \
    echo "Built FrankenPHP source @ $(git rev-parse HEAD) ($(git log -1 --format=%cI HEAD))"


# CGO must be enabled to build FrankenPHP
ENV CGO_ENABLED=1 XCADDY_SETCAP=1 XCADDY_GO_BUILD_FLAGS='-ldflags="-w -s" -trimpath'

COPY ./sidekick/middleware/cache ./cache

# Sellie fork: CGO_CFLAGS/CGO_LDFLAGS via php-config.
# The bundled v1.12.2 source has hardcoded `// #cgo CFLAGS: -I...`
# directives that match the builder image's PHP install path, so xcaddy
# build "just worked" against the bundled source without explicit
# CGO_CFLAGS. HEAD removed those hardcoded paths in favor of the
# documented build pattern (frankenphp.dev/docs/compile): callers feed
# php-config output into CGO_*. Without these flags, HEAD's
# `frankenphp.h:44 #include <Zend/zend_modules.h>` fails with
# "No such file or directory".
RUN CGO_CFLAGS="$(php-config --includes)" \
    CGO_LDFLAGS="-pie $(php-config --ldflags) $(php-config --libs)" \
    xcaddy build \
    --output /usr/local/bin/frankenphp \
    --with github.com/dunglas/frankenphp=./ \
    --with github.com/dunglas/frankenphp/caddy=./caddy/ \
    --with github.com/dunglas/caddy-cbrotli \
    --with github.com/stephenmiracle/frankenwp/sidekick/middleware/cache=./cache \
    # Sellie fork additions:
    #
    # caddy-ratelimit: per-IP/path rate limiting (e.g. brute-force
    # protection on /wp-login.php POST). Owned by mholt (Caddy
    # maintainer); apache-2.0; sliding-window algorithm. We wire a
    # default zone in Caddyfile that operators tune via env.
    # https://github.com/mholt/caddy-ratelimit
    --with github.com/mholt/caddy-ratelimit \
    # caddy-cache-handler (Souin): distributed HTTP cache handler.
    # Built-in here as an OPTION for operators that want to migrate
    # off sidekick — Souin has more features (distributed cache,
    # stale-while-revalidate, ETag handling) but our mu-plugin still
    # purges via sidekick's /__cache/purge API. Not enabled in the
    # baseline Caddyfile; operators activate via CADDY_GLOBAL_OPTIONS
    # + CADDY_SERVER_EXTRA_DIRECTIVES (`cache { ... }` directives).
    # https://github.com/caddyserver/cache-handler
    --with github.com/caddyserver/cache-handler


FROM wordpress:$WORDPRESS_VERSION AS wp
FROM dunglas/frankenphp:${FRANKENPHP_TAG}-php${PHP_VERSION} AS base

# Args declared before the first FROM are global but each FROM resets
# the stage-local ARG namespace — re-declare the ones we reference in
# this stage (was UndefinedVar build warning on $USER at line 236).
ARG USER=www-data

LABEL org.opencontainers.image.title=FrankenWP
LABEL org.opencontainers.image.description="Sellie fork — FrankenWP hardened for production behind a TLS-terminating edge. PHP 8.5 + FrankenPHP HEAD."
LABEL org.opencontainers.image.url=https://github.com/connorblack/frankenwp
LABEL org.opencontainers.image.source=https://github.com/connorblack/frankenwp
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="Connor Black (sellie fork of Stephen Miracle's frankenwp)"


# Replace the official binary by the one contained your custom modules
COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp
# Sellie fork: default FORCE_HTTPS to 1 so wp-config-docker.php's
# `if (!!getenv("FORCE_HTTPS")) { $_SERVER["HTTPS"] = "on"; }` fires by
# default. Upstream `=0` broke is_ssl() for every WP behind a TLS-
# terminating edge (Cloudflare, ALB, Fastly, etc.) and triggered
# /wp-admin/ redirect loops. Set FORCE_HTTPS=0 explicitly to opt out.
ENV FORCE_HTTPS=1

# Go runtime tuning for containerized FrankenPHP.
#
# GODEBUG=cgocheck=0 — already the default in dunglas/frankenphp images
# per https://frankenphp.dev/docs/performance/, but we set explicitly
# so it's grep-discoverable. Disables Go's CGO pointer-passing checks
# which add ~10-20% overhead on every PHP↔Go call (every request).
#
# GOMEMLIMIT — soft memory cap that Go GC honors. Without it the Go
# runtime doesn't observe the container's cgroup memory limit and runs
# GC too lazily; under bursty load this leads to OOM kills mid-request.
# Setting to 80% of `containerMemory` gives Go headroom to GC before
# hitting the hard limit. Operators MUST set this at deploy time to
# match their actual container memory (e.g. GOMEMLIMIT=1638MiB for a
# 2 GB container). The "0" default here is interpreted by Go as
# "no limit" (= status quo, no regression vs not setting).
# https://pkg.go.dev/runtime#hdr-Environment_Variables
ENV GODEBUG=cgocheck=0
ENV GOMEMLIMIT=0
# Sellie fork removed upstream's `ENV WP_DEBUG=${DEBUG:+1}` line — that
# line had no effect because wp-config-docker.php reads `WORDPRESS_DEBUG`
# (not `WP_DEBUG`), and it also emitted an UndefinedVar build warning
# because `$DEBUG` is not declared. Operators enable WP debug via
# `WORDPRESS_DEBUG=1` in their env file.
ENV PHP_INI_SCAN_DIR=$PHP_INI_DIR/conf.d


# Runtime-only deps. install-php-extensions auto-installs build-time
# headers (libonig-dev, libxml2-dev, etc.) and removes them after
# compile, so the upstream pre-install of dev headers was redundant
# AND bloated the image (those packages don't get auto-removed since
# the installer only cleans up the packages IT added). Sellie fork:
# reduced to genuine runtime needs only.
#
# Removed vs upstream: ghostscript (CVE magnet — Imagick's PDF→raster
# delegate is not needed for typical WP image processing); git, unzip
# (build-time only — not used at runtime); all -dev packages
# (install-php-extensions handles its own deps).
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*


# install the PHP extensions we need (https://make.wordpress.org/hosting/handbook/handbook/server-environment/#php-extensions)
#
# Sellie fork additions vs upstream:
#
#   * redis: pre-install the extension so operators can drop in the
#     rhubarbgroup/redis-cache WordPress plugin and get object cache
#     out of the box without rebuilding. Adds ~2 MB (libhiredis).
#     https://wordpress.org/plugins/redis-cache/
#
#   * opcache REMOVED from the install list AND the inherited
#     docker-php-ext-opcache.ini gets deleted. Why:
#
#     dunglas/frankenphp builds PHP with opcache as a STATIC extension
#     (compiled into the PHP binary itself), not a shared module. The
#     `php` binary therefore has opcache available without any
#     `zend_extension=opcache.so` directive. But the upstream `php`
#     image (which dunglas/frankenphp inherits from) ships
#     `docker-php-ext-opcache.ini` containing `zend_extension=opcache`
#     for the SHARED-module case — and that directive ACTIVELY BREAKS
#     the static opcache: PHP tries to dlopen() opcache.so, fails
#     ("Failed loading Zend extension 'opcache'... No such file"),
#     and the static module never registers either. Net effect:
#     opcache is silently disabled in BOTH SAPI and CLI.
#
#     Removing the inherited .ini lets the static opcache load
#     normally. Verified empirically (2026-04-15) on wp-smoke:
#     before removal — `extension_loaded("Zend OPcache")` = false,
#     `function_exists("opcache_get_status")` = false. After removal
#     + container restart — both true, `opcache_get_status()` shows
#     `{"enabled":true,"on":true,"kind":5,"buffer_size":67108848}`
#     proving JIT (kind=5 = tracing) is active with our 64M buffer
#     env-substitution honored. CLI warning also gone.
#
#     `install-php-extensions opcache` is correctly omitted because:
#     (a) it can't install opcache (it's static, no .so to compile —
#     `make install-modules` errors with "cannot stat 'modules/*'"),
#     and (b) it would re-create the broken docker-php-ext-opcache.ini
#     immediately after we delete it.
RUN install-php-extensions \
    bcmath \
    exif \
    gd \
    intl \
    mysqli \
    redis \
    zip \
    # See https://github.com/Imagick/imagick/issues/640#issuecomment-2077206945
    imagick/imagick@master \
    && rm -f $PHP_INI_DIR/conf.d/docker-php-ext-opcache.ini


RUN cp $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini
COPY php.ini $PHP_INI_DIR/conf.d/wp.ini

COPY --from=wp /usr/src/wordpress /usr/src/wordpress
COPY --from=wp /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d/
COPY --from=wp /usr/local/bin/docker-entrypoint.sh /usr/local/bin/


# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
#
# Sellie fork tuning vs upstream (which used the docker-php defaults
# from 2018-era PHP 7.x):
#   - memory_consumption: 128 → 256 MB. Real WP installs (core +
#     Uncode + WPResidence + ~30 plugins) easily compile 50-80 MB
#     of bytecode; 128 MB caused OPcache restarts mid-day on a busy
#     site, which is what the `oom_restarts` counter would surface.
#   - max_accelerated_files: 4000 → 10000. Same reason — WP file
#     count blows past 4000 on any non-trivial install.
#   - interned_strings_buffer: 8 → 16 MB. WP creates many short-lived
#     interned strings (post meta keys, taxonomy terms, hook names);
#     the upstream 8 MB default exhausts within a few hours.
#   - revalidate_freq: 2 → 60 seconds. Trades ~30s staleness on
#     in-place edits for ~30x fewer stat() syscalls per request.
#     Opcache reset on deploy still works because the container
#     restarts; this only delays the rare in-container `wp file edit`
#     case. validate_timestamps stays at 1 (the default) — turning
#     it off would break WP plugin updates from the dashboard.
#
# JIT is env-gated via OPCACHE_JIT (default `tracing` per PHP 8.5
# upstream recommendation). Set OPCACHE_JIT=off to disable; set
# OPCACHE_JIT_BUFFER_SIZE to override the 64M default. Tracing JIT
# is the upstream-recommended general-purpose mode and ships enabled
# by default in PHP 8.4+ runtime, but we make it explicit here so
# operators can grep/audit what's running. WordPress workloads are
# DB-bound so the typical perf delta is ~5-10% on page generation,
# more on math-heavy plugins (WooCommerce calculations).
ENV OPCACHE_JIT=tracing
ENV OPCACHE_JIT_BUFFER_SIZE=64M
RUN set -eux; \
    { \
    echo 'opcache.memory_consumption=256'; \
    echo 'opcache.interned_strings_buffer=16'; \
    echo 'opcache.max_accelerated_files=10000'; \
    echo 'opcache.revalidate_freq=60'; \
    echo 'opcache.jit=${OPCACHE_JIT:-tracing}'; \
    echo 'opcache.jit_buffer_size=${OPCACHE_JIT_BUFFER_SIZE:-64M}'; \
    } > $PHP_INI_DIR/conf.d/opcache-recommended.ini
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging
RUN { \
    # https://www.php.net/manual/en/errorfunc.constants.php
    # https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
    echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
    echo 'display_errors = Off'; \
    echo 'display_startup_errors = Off'; \
    echo 'log_errors = On'; \
    echo 'error_log = /dev/stderr'; \
    echo 'log_errors_max_len = 1024'; \
    echo 'ignore_repeated_errors = On'; \
    echo 'ignore_repeated_source = Off'; \
    echo 'html_errors = Off'; \
    } > $PHP_INI_DIR/conf.d/error-logging.ini


WORKDIR /var/www/html

VOLUME /var/www/html/wp-content


COPY wp-content/mu-plugins /var/www/html/wp-content/mu-plugins
RUN mkdir /var/www/html/wp-content/cache



RUN sed -i \
    -e 's/\[ "$1" = '\''php-fpm'\'' \]/\[\[ "$1" == frankenphp* \]\]/g' \
    -e 's/php-fpm/frankenphp/g' \
    /usr/local/bin/docker-entrypoint.sh



# Inject runtime overrides into wp-config-docker.php's `<?php` opening
# so they apply to every request before WP bootstraps. Each env var is
# checked at runtime — operators flip behavior without rebuilding.
#
#   1. FORCE_HTTPS=1 → $_SERVER['HTTPS']='on' so is_ssl() returns true
#      behind a TLS-terminating edge (Cloudflare, ALB, Fastly).
#      Documented as upstream FrankenWP behavior; sellie fork defaults
#      the env var to 1 (see ENV FORCE_HTTPS=1 above).
#
#   2. DISABLE_WP_CRON=1 → define('DISABLE_WP_CRON', true) so WP doesn't
#      spawn cron-on-pageview. WP cron-on-pageview is unreliable under
#      edge cache (cached HTML = no pageview = no cron). Operators MUST
#      schedule wp-cron.php externally (Coolify scheduled task, host
#      crontab, etc.) when this is enabled. Default is unset (cron
#      stays enabled, matches stock WP behavior); set to 1 in your
#      env file when you've wired up an external scheduler.
#      Sellie fork addition — upstream wp-config-docker.php has no
#      env-var hook for this (verified docker-library/wordpress source).
#
#   3. DISALLOW_FILE_EDIT=1 → define('DISALLOW_FILE_EDIT', true) so the
#      WP admin's plugin/theme code editor is removed entirely. This is
#      WordPress's own "Hardening WordPress" recommendation
#      (developer.wordpress.org/advanced-administration/security/hardening)
#      — without it, anyone who pivots dashboard access into edit_themes
#      capability gets RCE for free via the editor. Strongly recommended
#      for production; default unset (= editor stays available, matches
#      stock WP behavior so we don't surprise existing operators).
#
#   4. FS_METHOD=direct, set_time_limit(300) — upstream FrankenWP
#      defaults; kept verbatim.
#
# Other constants (WP_AUTO_UPDATE_CORE, DISALLOW_FILE_MODS, etc.) take
# string-or-boolean values that don't round-trip cleanly through env →
# getenv(). Operators set them via WORDPRESS_CONFIG_EXTRA which the
# upstream wp-config-docker.php evals verbatim, e.g.:
#   WORDPRESS_CONFIG_EXTRA="define('WP_AUTO_UPDATE_CORE', 'minor');"
#
# Sed delimiter is | (not /) so the PHP code with its quoting plays
# nicely. Backslash continuations within a single Dockerfile RUN are
# eaten by the shell, so the resulting sed sees one long line.
RUN sed -i 's|<?php|<?php \
if (!!getenv("FORCE_HTTPS"))        { \$_SERVER["HTTPS"] = "on"; } \
if (!!getenv("DISABLE_WP_CRON"))    { define("DISABLE_WP_CRON", true); } \
if (!!getenv("DISALLOW_FILE_EDIT")) { define("DISALLOW_FILE_EDIT", true); } \
define("FS_METHOD", "direct"); \
set_time_limit(300); |g' /usr/src/wordpress/wp-config-docker.php

# Adding WordPress CLI
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    chmod +x wp-cli.phar && \
    mv wp-cli.phar /usr/local/bin/wp

COPY Caddyfile /etc/caddy/Caddyfile

# Caddy requires CAP_NET_BIND_SERVICE to bind to ports below 1024 as
# the non-root www-data user.
#
# Sellie fork: dropped upstream's `useradd -D ${USER}` prefix on this
# RUN. `useradd -D <name>` is invalid syntax — the -D flag prints
# defaults and ignores positional args on older Debians but errors on
# Trixie/current Bookworm useradd. www-data is already created by the
# upstream php base image (which dunglas/frankenphp extends), so the
# useradd was a no-op typo at best. Past builds passed only because
# GHA cache hits skipped the layer; the first true cold build on the
# new Dockerfile exposed it.
RUN setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp

# Caddy requires write access to /data/caddy and /config/caddy
RUN chown -R ${USER}:${USER} /data/caddy && \
    chown -R ${USER}:${USER} /config/caddy && \
    chown -R ${USER}:${USER} /var/www/html && \
    chown -R ${USER}:${USER} /usr/src/wordpress && \
    chown -R ${USER}:${USER} /usr/local/bin/docker-entrypoint.sh

USER $USER

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
