<?php
require __DIR__ . '/../app/Services/DeviceStatusEvaluator.php';
use App\Services\DeviceStatusEvaluator;

function assertEquals($expected, $actual, string $msg): void {
    if ($expected !== $actual) {
        fwrite(STDERR, "FAIL: $msg (expected " . var_export($expected, true) . ", got " . var_export($actual, true) . ")\n");
        exit(1);
    }
    echo "PASS: $msg\n";
}

// THE exact bug: minimum_supported_app_version (a key nothing ever wrote)
// was compared against, instead of the platform-specific key. These two
// cases are verbatim from the Iteration 1.1 review.
$android = DeviceStatusEvaluator::evaluate(
    platform: 'android', appVersion: '1.0.0', deviceRevoked: false, parishActive: true,
    minVersionAndroid: '1.2.0', minVersionIos: '5.0.0', // deliberately different, to prove no cross-platform mixup
);
assertEquals('UPDATE_REQUIRED', $android['state'], 'Android 1.0.0 / minimum Android 1.2.0 -> UPDATE_REQUIRED (verbatim review case)');

$ios = DeviceStatusEvaluator::evaluate(
    platform: 'ios', appVersion: '1.0.0', deviceRevoked: false, parishActive: true,
    minVersionAndroid: '5.0.0', minVersionIos: '0.9.0', // deliberately different
);
assertEquals('ACTIVE', $ios['state'], 'iOS 1.0.0 / minimum iOS 0.9.0 -> ACTIVE (verbatim review case)');

// Sanity: the old bug's exact symptom — a key nothing writes — must NOT
// silently make everyone ACTIVE forever once real keys are wired in.
$androidBlocked = DeviceStatusEvaluator::evaluate(
    platform: 'android', appVersion: '0.5.0', deviceRevoked: false, parishActive: true,
    minVersionAndroid: '1.0.0', minVersionIos: null,
);
assertEquals('UPDATE_REQUIRED', $androidBlocked['state'], 'an old Android build is blocked when only the Android minimum is set (iOS minimum absent/irrelevant)');

// Priority order: revoked / parish-disabled beat UPDATE_REQUIRED.
$revoked = DeviceStatusEvaluator::evaluate(
    platform: 'android', appVersion: '0.1.0', deviceRevoked: true, parishActive: true,
    minVersionAndroid: '1.0.0', minVersionIos: null,
);
assertEquals('DEVICE_REVOKED', $revoked['state'], 'DEVICE_REVOKED takes priority even when the app is also outdated');

$disabled = DeviceStatusEvaluator::evaluate(
    platform: 'android', appVersion: '0.1.0', deviceRevoked: false, parishActive: false,
    minVersionAndroid: '1.0.0', minVersionIos: null,
);
assertEquals('PARISH_DISABLED', $disabled['state'], 'PARISH_DISABLED takes priority over UPDATE_REQUIRED');

// No minimum configured at all -> never blocks.
$noMin = DeviceStatusEvaluator::evaluate(
    platform: 'ios', appVersion: '0.0.1', deviceRevoked: false, parishActive: true,
    minVersionAndroid: null, minVersionIos: null,
);
assertEquals('ACTIVE', $noMin['state'], 'with no minimum version configured for the platform, even a very old build is ACTIVE');

echo "\nAll DeviceStatusEvaluator tests passed — including both verbatim Iteration 1.1 review cases.\n";
