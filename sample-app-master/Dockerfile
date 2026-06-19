FROM php:8.2-apache

# dépendances système
RUN apt-get update && apt-get install -y \
    libpq-dev \
    git unzip libzip-dev zip \
    libpng-dev libjpeg-dev libfreetype6-dev

# extensions PHP
RUN docker-php-ext-install \
    pdo \
    pdo_mysql \
    pdo_pgsql \
    pgsql \
    zip

# composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# apache config
RUN a2enmod rewrite

ENV APACHE_DOCUMENT_ROOT=/var/www/html/public

RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf \
 && sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf

# code
WORKDIR /var/www/html
COPY . .

# permissions propres (IMPORTANT)
RUN chown -R www-data:www-data /var/www/html \
 && chmod -R 755 /var/www/html/storage

# dépendances Laravel
RUN composer install --no-interaction --prefer-dist --optimize-autoloader

# cache config/route/view (ne doit pas casser la build)
RUN php artisan config:cache || true
RUN php artisan route:cache || true
RUN php artisan view:cache || true

COPY entrypoint.sh /entrypoint.sh

RUN sed -i 's/\r$//' /entrypoint.sh \
 && chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/bin/sh","/entrypoint.sh"]