<?php

// Minimal Laravel contender for the framework comparison: serves the three
// TechEmpower-style endpoints, nothing else - same contract as every other
// contender (/plaintext text, /json json, /json-large ~62KB json, port 8080,
// keep-alive). This file replaces routes/web.php in a Laravel skeleton
// generated fresh at image-build time by `composer create-project` (see
// Dockerfile), served by PHP-FPM + nginx (the standard production pattern) -
// only this file, nginx.conf and large.json are committed to the repo.

use Illuminate\Support\Facades\Route;

Route::get('/plaintext', function () {
    return response('Hello, World!', 200)->header('Content-Type', 'text/plain');
});

Route::get('/json', function () {
    return response('{"message":"Hello, World!"}', 200)
        ->header('Content-Type', 'application/json');
});

Route::get('/json-large', function () {
    return response(file_get_contents(base_path('large.json')), 200)
        ->header('Content-Type', 'application/json');
});
