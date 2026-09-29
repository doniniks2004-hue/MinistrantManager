#!/usr/bin/env bash
# Iteration 1.1 point 12: turns a bare `composer create-project
# laravel/laravel` output into a runnable app.ministrant.eu by copying
# this package's application-specific files on top and wiring the one
# piece of glue Laravel 11 needs by hand (the middleware alias — see
# apply-middleware-alias.php). Used by .github/workflows/backend-test.yml
# so CI needs nothing done manually after checkout; also usable locally.
#
# Usage: ci/overlay-package.sh <path-to-package-root> <path-to-fresh-laravel-app>
set -euo pipefail

PACKAGE_ROOT="$1"
LARAVEL_APP="$2"

mkdir -p "$LARAVEL_APP/app/Http/Controllers/Admin" \
         "$LARAVEL_APP/app/Http/Controllers/Api" \
         "$LARAVEL_APP/app/Http/Controllers/Internal" \
         "$LARAVEL_APP/app/Http/Controllers/Public" \
         "$LARAVEL_APP/app/Http/Middleware" \
         "$LARAVEL_APP/app/Models" \
         "$LARAVEL_APP/app/Services"

cp -r "$PACKAGE_ROOT/app/Http/Controllers/Admin/." "$LARAVEL_APP/app/Http/Controllers/Admin/"
cp -r "$PACKAGE_ROOT/app/Http/Controllers/Api/." "$LARAVEL_APP/app/Http/Controllers/Api/"
cp -r "$PACKAGE_ROOT/app/Http/Controllers/Internal/." "$LARAVEL_APP/app/Http/Controllers/Internal/"
cp -r "$PACKAGE_ROOT/app/Http/Controllers/Public/." "$LARAVEL_APP/app/Http/Controllers/Public/"
cp "$PACKAGE_ROOT/app/Http/Controllers/Controller.php" "$LARAVEL_APP/app/Http/Controllers/Controller.php"
cp -r "$PACKAGE_ROOT/app/Http/Middleware/." "$LARAVEL_APP/app/Http/Middleware/"
cp -r "$PACKAGE_ROOT/app/Models/." "$LARAVEL_APP/app/Models/"
cp -r "$PACKAGE_ROOT/app/Services/." "$LARAVEL_APP/app/Services/"

cp -r "$PACKAGE_ROOT/database/migrations/." "$LARAVEL_APP/database/migrations/"

mkdir -p "$LARAVEL_APP/resources/views/admin" "$LARAVEL_APP/resources/views/public"
cp -r "$PACKAGE_ROOT/resources/views/admin/." "$LARAVEL_APP/resources/views/admin/"
cp -r "$PACKAGE_ROOT/resources/views/public/." "$LARAVEL_APP/resources/views/public/"

cp "$PACKAGE_ROOT/routes/web.php" "$LARAVEL_APP/routes/web.php"
cp "$PACKAGE_ROOT/routes/api.php" "$LARAVEL_APP/routes/api.php"
cp "$PACKAGE_ROOT/config/auth.php" "$LARAVEL_APP/config/auth.php"

if [ -d "$PACKAGE_ROOT/public/.well-known" ]; then
  mkdir -p "$LARAVEL_APP/public/.well-known"
  cp -r "$PACKAGE_ROOT/public/.well-known/." "$LARAVEL_APP/public/.well-known/"
fi

if [ -d "$PACKAGE_ROOT/tests/Feature" ]; then
  # Real CI result: the fresh Laravel skeleton's own tests/Feature/ExampleTest.php
  # (asserts GET / returns 200) was being merged alongside ours instead of
  # removed — our app correctly returns 302 (redirect to /admin) at that
  # route, so ExampleTest failed every run despite our own tests passing.
  # Remove ONLY the skeleton's own example tests — keep tests/TestCase.php
  # (our ActivationApiTest.php extends it) and any Pest bootstrap intact.
  rm -f "$LARAVEL_APP/tests/Feature/ExampleTest.php" "$LARAVEL_APP/tests/Unit/ExampleTest.php"
  mkdir -p "$LARAVEL_APP/tests/Feature"
  cp -r "$PACKAGE_ROOT/tests/Feature/." "$LARAVEL_APP/tests/Feature/"
fi

php "$PACKAGE_ROOT/ci/apply-middleware-alias.php" "$LARAVEL_APP/bootstrap/app.php"

# Review round 3, point 3: routes/api.php is copied above, but Laravel 11
# does not register it by default — without this, every /api/* route
# (including what ActivationApiTest.php exercises) 404s despite the file
# existing on disk.
php "$PACKAGE_ROOT/ci/enable-api-routing.php" "$LARAVEL_APP/bootstrap/app.php"

echo "overlay-package.sh: package overlaid onto $LARAVEL_APP"
