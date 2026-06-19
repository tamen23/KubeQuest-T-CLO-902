#!/bin/sh

php artisan migrate --force || true
chmod -R 777 /var/www/html/storage /var/www/html/bootstrap/cache || true

apache2-foreground
