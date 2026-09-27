<?php
/**
 * Review round 3, point 3: a bare `composer create-project laravel/laravel`
 * app does NOT register `routes/api.php` by default in Laravel 11 — API
 * routing is opt-in via the `api:` parameter of `->withRouting(...)` in
 * bootstrap/app.php. The previous CI setup copied routes/api.php's
 * CONTENTS into the fresh app but never actually wired it into the
 * router, so `POST /api/activation/check` (and the Feature test that
 * hits it) would 404 despite the file existing on disk.
 *
 * This script inserts `api: __DIR__.'/../routes/api.php',` into Laravel
 * 11's generated `->withRouting(...)` call, right after its default
 * `web:` line.
 *
 * Usage: php ci/enable-api-routing.php path/to/bootstrap/app.php
 *
 * Fragile-but-documented, same posture as apply-middleware-alias.php:
 * greps for the exact generated text and fails loudly (non-zero exit) if
 * it's not found, rather than silently no-op'ing — so CI catches
 * skeleton drift instead of quietly running with API routes still
 * unregistered.
 */

$path = $argv[1] ?? null;
if (!$path || !file_exists($path)) {
    fwrite(STDERR, "Usage: php enable-api-routing.php path/to/bootstrap/app.php\n");
    exit(1);
}

$content = file_get_contents($path);

if (str_contains($content, "api: __DIR__.'/../routes/api.php'")) {
    // Idempotent: running this script twice (e.g. a re-run CI step) must
    // not double-insert the line.
    echo "enable-api-routing.php: api routing already registered in $path — nothing to do\n";
    exit(0);
}

$marker = "web: __DIR__.'/../routes/web.php',";

if (!str_contains($content, $marker)) {
    fwrite(STDERR, "enable-api-routing.php: expected marker not found in $path — Laravel's generated "
        . "bootstrap/app.php skeleton may have changed. Update \$marker in this script to match the current "
        . "->withRouting(...) call's web: line.\n");
    exit(1);
}

$injection = "web: __DIR__.'/../routes/web.php',\n        api: __DIR__.'/../routes/api.php',";
$content = str_replace($marker, $injection, $content);
file_put_contents($path, $content);

echo "enable-api-routing.php: registered routes/api.php via withRouting(api: ...) in $path\n";
