<?php
// Standalone executable test — no Laravel framework needed, since
// TokenService has zero framework dependencies. Run with: php test_token_service.php
require __DIR__ . '/../app/Services/TokenService.php';

use App\Services\TokenService;

function assertTrue(bool $cond, string $msg): void {
    if (!$cond) { fwrite(STDERR, "FAIL: $msg\n"); exit(1); }
    echo "PASS: $msg\n";
}

// 1. Activation token: 64 hex chars, unique across calls
$t1 = TokenService::generateActivationToken();
$t2 = TokenService::generateActivationToken();
assertTrue(strlen($t1) === 64, 'activation token is 64 hex chars');
assertTrue(ctype_xdigit($t1), 'activation token is valid hex');
assertTrue($t1 !== $t2, 'two activation tokens are not equal (entropy sanity check)');

// 2. Device token: same shape
$d1 = TokenService::generateDeviceToken();
assertTrue(strlen($d1) === 64 && ctype_xdigit($d1), 'device token is 64 hex chars');

// 3. Display code shape: XXXX-XXXX, uppercase, no ambiguous chars (0/O/1/I)
for ($i = 0; $i < 500; $i++) {
    $code = TokenService::generateDisplayCode();
    assertTrue((bool) preg_match('/^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/', $code), "display code '$code' matches expected charset/shape");
}

// 4. hash() is deterministic SHA-256 and never returns the raw input
$raw = 'some-raw-token-value';
$h1 = TokenService::hash($raw);
$h2 = TokenService::hash($raw);
assertTrue($h1 === $h2, 'hash() is deterministic for the same input');
assertTrue($h1 === hash('sha256', $raw), 'hash() actually uses sha256');
assertTrue($h1 !== $raw, 'hash() never returns the raw value unchanged');

echo "\nAll TokenService tests passed.\n";
