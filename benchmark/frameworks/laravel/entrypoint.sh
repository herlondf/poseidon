#!/bin/sh
# Starts PHP-FPM in the background and nginx in the foreground - the
# standard production pattern for Laravel (LEMP), so both processes share
# one container without needing a separate orchestrator/supervisor.
set -e
php-fpm -D
exec nginx -c /app/nginx.conf
