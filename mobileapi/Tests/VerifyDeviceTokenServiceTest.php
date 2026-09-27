<?php
require __DIR__ . '/autoload.php';

use MinistrantManager\MobileAPI\Middleware\VerifyDeviceTokenService;
use MinistrantManager\MobileAPI\Repositories\Fake\FakeDeviceTokenStore;

function assertEquals($expected, $actual, string $msg): void {
    if ($expected !== $actual) {
        fwrite(STDERR, "FAIL: $msg (expected " . var_export($expected, true) . ", got " . var_export($actual, true) . ")\n");
        exit(1);
    }
    echo "PASS: $msg\n";
}

$store = new FakeDeviceTokenStore();
$store->seed('token-chwk-device-1', parishId: 'chwk-id', status: 'active', parishStatus: 'active');
$store->seed('token-xyz-device-1', parishId: 'xyz-id', status: 'active', parishStatus: 'active');
$store->seed('token-chwk-revoked', parishId: 'chwk-id', status: 'revoked', parishStatus: 'active');
$store->seed('token-chwk-parish-disabled', parishId: 'chwk-id', status: 'active', parishStatus: 'disabled');

$service = new VerifyDeviceTokenService($store);

// 1. Happy path: CHWK token used against CHWK subdomain.
$r1 = $service->verify('token-chwk-device-1', currentParishId: 'chwk-id');
assertEquals(true, $r1->ok, 'CHWK token against CHWK subdomain succeeds');

// 2. THE spec §36 test, verbatim: token activated for CHWK, then used
// against xyz.ministrant.eu's bootstrap endpoint.
$r2 = $service->verify('token-chwk-device-1', currentParishId: 'xyz-id');
assertEquals(false, $r2->ok, 'CHWK token against xyz subdomain is rejected');
assertEquals('TENANT_MISMATCH', $r2->code, 'rejection reason is exactly TENANT_MISMATCH');
assertEquals(403, $r2->httpStatus(), 'TENANT_MISMATCH maps to HTTP 403');

// 3. A DIFFERENT parish's own token still works fine against its own subdomain.
$r3 = $service->verify('token-xyz-device-1', currentParishId: 'xyz-id');
assertEquals(true, $r3->ok, 'xyz token against xyz subdomain still succeeds (isolation is not a blanket lockout)');

// 4. Revoked device.
$r4 = $service->verify('token-chwk-revoked', currentParishId: 'chwk-id');
assertEquals(false, $r4->ok, 'revoked device token is rejected even against its own correct parish');
assertEquals('DEVICE_REVOKED', $r4->code, 'rejection reason is DEVICE_REVOKED');

// 5. Parish disabled.
$r5 = $service->verify('token-chwk-parish-disabled', currentParishId: 'chwk-id');
assertEquals(false, $r5->ok, 'device on a disabled parish is rejected');
assertEquals('PARISH_DISABLED', $r5->code, 'rejection reason is PARISH_DISABLED');

// 6. Missing / unknown token.
$r6 = $service->verify(null, currentParishId: 'chwk-id');
assertEquals('MISSING_TOKEN', $r6->code, 'null token is MISSING_TOKEN, not a crash');
$r7 = $service->verify('totally-made-up-token', currentParishId: 'chwk-id');
assertEquals('INVALID_TOKEN', $r7->code, 'unknown token is INVALID_TOKEN');

echo "\nAll VerifyDeviceTokenService tests passed — including the spec §36 tenant-isolation test verbatim.\n";
