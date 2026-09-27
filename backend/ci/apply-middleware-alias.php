<?php
/**
 * Iteration 1.1 point 12: CI must be able to go from a bare
 * `composer create-project laravel/laravel` to a running app.ministrant.eu
 * WITHOUT a human manually editing bootstrap/app.php first. This script
 * does exactly the one manual step bootstrap/app.middleware-snippet.php
 * used to require by hand: inserting the 'super_admin' middleware alias
 * registration into a freshly generated Laravel 11 bootstrap/app.php.
 *
 * Usage: php ci/apply-middleware-alias.php path/to/bootstrap/app.php
 *
 * Fragile-but-documented: this greps for Laravel 11's default
 * ->withMiddleware(function (Middleware $middleware) { and inserts one
 * line right after it. If a future Laravel version changes that generated
 * skeleton's exact text, this script's $marker must be updated to match —
 * it deliberately fails loudly (non-zero exit) rather than silently
 * no-op'ing, so CI catches that drift instead of quietly running with an
 * unregistered middleware alias.
 */

$path = $argv[1] ?? null;
if (!$path || !file_exists($path)) {
    fwrite(STDERR, "Usage: php apply-middleware-alias.php path/to/bootstrap/app.php\n");
    exit(1);
}

$content = file_get_contents($path);
$marker = '->withMiddleware(function (Middleware $middleware) {';

if (!str_contains($content, $marker)) {
    fwrite(STDERR, "apply-middleware-alias.php: expected marker not found in $path — Laravel's generated "
        . "bootstrap/app.php skeleton may have changed. Update \$marker in this script to match the current "
        . "->withMiddleware(...) closure signature.\n");
    exit(1);
}

$injection = "        \$middleware->alias(['super_admin' => \\App\\Http\\Middleware\\EnsureSuperAdmin::class]);\n";

$content = str_replace($marker, $marker . "\n" . $injection, $content);
file_put_contents($path, $content);

echo "apply-middleware-alias.php: registered 'super_admin' middleware alias in $path\n";
