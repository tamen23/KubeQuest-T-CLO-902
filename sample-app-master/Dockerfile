# --- builder: installs Composer deps with dev tools, discarded after ------
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
# --no-scripts: this stage has no app code yet, so post-install artisan
# hooks (package:discover etc.) would fail; --no-dev drops phpunit and other
# dev-only packages entirely out of the shipped image.
RUN composer install --no-interaction --prefer-dist --optimize-autoloader \
    --no-dev --no-scripts

# --- runtime: slim final image --------------------------------------------
FROM php:8.2-apache

# System deps trimmed to only what the PHP extensions below need to build +
# run; git/unzip/zip (composer's own tools) are NOT needed here since
# vendor/ is copied pre-built from the `vendor` stage above. The `-dev`
# packages are needed only to COMPILE the extensions below (headers, .so
# symlinks for the linker) -- `apt-mark manual` on their corresponding
# runtime libs before purging keeps the actual .so files the compiled
# extensions load at runtime (libpq.so.5, libzip.so.5, etc), while dropping
# the headers/dev tooling that add bulk with zero runtime benefit.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    libzip-dev \
    libpng-dev libjpeg-dev libfreetype6-dev \
    && docker-php-ext-install pdo pdo_mysql pdo_pgsql pgsql zip \
    && a2enmod rewrite \
    && apt-mark manual libpq5 libzip5 libpng16-16t64 libjpeg62-turbo libfreetype6 \
    && apt-get purge -y --auto-remove libpq-dev libzip-dev libpng-dev libjpeg-dev libfreetype6-dev \
    && rm -rf /var/lib/apt/lists/*

ENV APACHE_DOCUMENT_ROOT=/var/www/html/public

RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf \
 && sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf

WORKDIR /var/www/html

# App code first (see .dockerignore for what's excluded: tests/, docs,
# docker-compose.yaml, etc. — none of it is needed at runtime).
COPY . .
# Pre-built vendor/ from the composer stage — no composer, git, zip, or
# dev-only packages in the final image at all.
COPY --from=vendor /app/vendor ./vendor

RUN chown -R www-data:www-data /var/www/html \
 && chmod -R 755 /var/www/html/storage

COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
