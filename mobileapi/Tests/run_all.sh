#!/usr/bin/env bash
# Runs every framework-free test in this directory with plain `php`.
# No PHPUnit, no Composer, no Laravel — see docs/TESTING.md for why.
set -e
cd "$(dirname "$0")"
for f in *Test.php; do
    echo "=== $f ==="
    php "$f"
    echo
done
echo "ALL MOBILEAPI STANDALONE TESTS PASSED"
