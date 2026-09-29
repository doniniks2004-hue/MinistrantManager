<?php
require __DIR__ . '/../app/Services/DeviceValidationEvaluator.php';
use App\Services\DeviceValidationEvaluator;

function assertEquals($expected, $actual, string $msg): void {
    if ($expected !== $actual) {
        fwrite(STDERR, "FAIL: $msg (expected " . var_export($expected, true) . ", got " . var_export($actual, true) . ")\n");
        exit(1);
    }
    echo "PASS: $msg\n";
}

// The straightforward happy path.
$active = DeviceValidationEvaluator::evaluate(
    device: ['parish_id' => 42, 'status' => 'active'],
    requestingParishId: 42,
    requestingParishActive: true,
    offlineLeaseHours: 72,
);
assertEquals('active', $active['state'], 'device active, same parish, requesting parish active -> active');
assertEquals(72, $active['offline_lease_hours'], 'offline_lease_hours is passed through so the parish can cap its own stale-cache fallback against it');

// Device genuinely doesn't exist.
$notFound = DeviceValidationEvaluator::evaluate(
    device: null,
    requestingParishId: 42,
    requestingParishActive: true,
    offlineLeaseHours: 72,
);
assertEquals('not_found', $notFound['state'], 'no MobileDevice row at all -> not_found');

// Device revoked centrally.
$revoked = DeviceValidationEvaluator::evaluate(
    device: ['parish_id' => 42, 'status' => 'revoked'],
    requestingParishId: 42,
    requestingParishActive: true,
    offlineLeaseHours: 72,
);
assertEquals('revoked', $revoked['state'], 'device status=revoked, same parish -> revoked');

// THE security-critical case: a device that genuinely exists and is
// active, but belongs to a DIFFERENT parish than the one asking — this
// must NEVER come back as "active" just because the device itself is
// fine. Review round: "Nie opieraj bezpieczeństwa na hostname przesłanym
// przez klienta" — parish_id here is the AUTHENTICATED identity (from
// the secret), never something the caller merely claims.
$mismatch = DeviceValidationEvaluator::evaluate(
    device: ['parish_id' => 99, 'status' => 'active'],
    requestingParishId: 42,
    requestingParishActive: true,
    offlineLeaseHours: 72,
);
assertEquals('parish_mismatch', $mismatch['state'], 'device belongs to parish 99, but parish 42 (authenticated) is asking -> parish_mismatch, NEVER active');

// The requesting parish itself is disabled — must block regardless of
// which installation_id it asks about, even its own previously-fine device.
$requesterDisabled = DeviceValidationEvaluator::evaluate(
    device: ['parish_id' => 42, 'status' => 'active'],
    requestingParishId: 42,
    requestingParishActive: false,
    offlineLeaseHours: 72,
);
assertEquals('parish_disabled', $requesterDisabled['state'], 'requesting parish itself disabled -> parish_disabled, even for its own active device');

// Priority: a disabled requester beats even parish_mismatch — a
// disabled parish gets no information via this endpoint at all, not
// even "that installation belongs to someone else".
$disabledAndMismatch = DeviceValidationEvaluator::evaluate(
    device: ['parish_id' => 99, 'status' => 'active'],
    requestingParishId: 42,
    requestingParishActive: false,
    offlineLeaseHours: 72,
);
assertEquals('parish_disabled', $disabledAndMismatch['state'], 'a disabled requesting parish is blocked before any device/parish-match check even runs');

// Priority: revoked device beats nothing else here since parish already
// matches — but confirm it is NOT masked by any other check.
$revokedOwnParish = DeviceValidationEvaluator::evaluate(
    device: ['parish_id' => 7, 'status' => 'revoked'],
    requestingParishId: 7,
    requestingParishActive: true,
    offlineLeaseHours: 72,
);
assertEquals('revoked', $revokedOwnParish['state'], 'revoked device, matching parish, requester active -> revoked (not active)');

echo "\nAll DeviceValidationEvaluator tests passed.\n";
