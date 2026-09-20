# Laravel itself is resolved fresh via `composer create-project` (Composer
# packages from Packagist at build time) - nothing framework-related is
# vendored into this repo, only web.php/nginx.conf/entrypoint.sh/large.json.
# Served by PHP-FPM + nginx (LEMP), the standard production pattern - not
# php artisan serve's single-process dev server.
FROM composer:2 AS build
WORKDIR /build
RUN composer create-project --no-interaction --prefer-dist laravel/laravel .
# No route here touches a database or needs session persistence - Laravel's
# default .env points SESSION_DRIVER/CACHE_STORE at a SQLite file that the
# web-server user cannot write to inside this image, which faulted the
# session-save middleware every request. array (in-memory, no file/DB) sidesteps
# that entirely instead of chasing SQLite file permissions we do not need.
RUN sed -i -e 's/^SESSION_DRIVER=.*/SESSION_DRIVER=array/' \
           -e 's/^CACHE_STORE=.*/CACHE_STORE=array/' .env

FROM php:8.4-fpm
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends nginx \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build ./
COPY web.php routes/web.php
COPY large.json ./large.json
COPY nginx.conf ./nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown -R www-data:www-data /app/storage /app/bootstrap/cache
EXPOSE 8080
CMD ["/entrypoint.sh"]
