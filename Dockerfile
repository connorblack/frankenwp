ARG WORDPRESS_VERSION=latest
# Sellie fork: PHP 8.5 default (was 8.3). FrankenPHP's `latest-php8.5`
# rolling tag doesn't exist on Docker Hub even though they ship 8.5
# in their numbered releases — we pin to the `1-*-php8.5` track to
# get PHP 8.5 while still tracking 1.x patch updates.
ARG PHP_VERSION=8.5
ARG FRANKENPHP_TAG=1
ARG USER=www-data



FROM dunglas/frankenphp:${FRANKENPHP_TAG}-builder-php${PHP_VERSION} as builder

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

RUN xcaddy build \
    --output /usr/local/bin/frankenphp \
    --with github.com/dunglas/frankenphp=./ \
    --with github.com/dunglas/frankenphp/caddy=./caddy/ \
    --with github.com/dunglas/caddy-cbrotli \
    # Add extra Caddy modules here
    --with github.com/stephenmiracle/frankenwp/sidekick/middleware/cache=./cache


FROM wordpress:$WORDPRESS_VERSION as wp
FROM dunglas/frankenphp:${FRANKENPHP_TAG}-php${PHP_VERSION} AS base

LABEL org.opencontainers.image.title=FrankenWP
LABEL org.opencontainers.image.description="Optimized WordPress containers to run everywhere. Built with FrankenPHP & Caddy."
LABEL org.opencontainers.image.url=https://wpeverywhere.com
LABEL org.opencontainers.image.source=https://github.com/StephenMiracle/frankenwp
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="Stephen Miracle"


# Replace the official binary by the one contained your custom modules
COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp
ENV WP_DEBUG=${DEBUG:+1}
# Sellie fork: default FORCE_HTTPS to 1 so wp-config-docker.php's
# `if (!!getenv("FORCE_HTTPS")) { $_SERVER["HTTPS"] = "on"; }` fires by
# default. Upstream `=0` broke is_ssl() for every WP behind a TLS-
# terminating edge (Cloudflare, ALB, Fastly, etc.) and triggered
# /wp-admin/ redirect loops. Set FORCE_HTTPS=0 explicitly to opt out.
ENV FORCE_HTTPS=1
ENV PHP_INI_SCAN_DIR=$PHP_INI_DIR/conf.d


RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    ghostscript \
    curl \
    libonig-dev \
    libxml2-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libzip-dev \
    unzip \
    git \
    libjpeg-dev \
    libwebp-dev \
    libzip-dev \
    libmemcached-dev \
    zlib1g-dev


# install the PHP extensions we need (https://make.wordpress.org/hosting/handbook/handbook/server-environment/#php-extensions)
RUN install-php-extensions \
    bcmath \
    exif \
    gd \
    intl \
    mysqli \
    zip \
    # See https://github.com/Imagick/imagick/issues/640#issuecomment-2077206945
    imagick/imagick@master \
    opcache


RUN cp $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini
COPY php.ini $PHP_INI_DIR/conf.d/wp.ini

COPY --from=wp /usr/src/wordpress /usr/src/wordpress
COPY --from=wp /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d/
COPY --from=wp /usr/local/bin/docker-entrypoint.sh /usr/local/bin/


# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN set -eux; \
    { \
    echo 'opcache.memory_consumption=128'; \
    echo 'opcache.interned_strings_buffer=8'; \
    echo 'opcache.max_accelerated_files=4000'; \
    echo 'opcache.revalidate_freq=2'; \
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



# Add $_SERVER['ssl'] = true; when env USE_SSL = true is set to the wp-config.php file here: /usr/local/bin/wp-config-docker.php
RUN sed -i 's/<?php/<?php if (!!getenv("FORCE_HTTPS")) { \$_SERVER["HTTPS"] = "on"; } define( "FS_METHOD", "direct" ); set_time_limit(300); /g' /usr/src/wordpress/wp-config-docker.php

# Adding WordPress CLI
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    chmod +x wp-cli.phar && \
    mv wp-cli.phar /usr/local/bin/wp

COPY Caddyfile /etc/caddy/Caddyfile

# Caddy requires an additional capability to bind to port 80 and 443
RUN useradd -D ${USER} && \
    setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp

# Caddy requires write access to /data/caddy and /config/caddy
RUN chown -R ${USER}:${USER} /data/caddy && \
    chown -R ${USER}:${USER} /config/caddy && \
    chown -R ${USER}:${USER} /var/www/html && \
    chown -R ${USER}:${USER} /usr/src/wordpress && \
    chown -R ${USER}:${USER} /usr/local/bin/docker-entrypoint.sh

USER $USER

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
