#!/bin/sh

php artisan migrate --force || true

apache2-foreground
