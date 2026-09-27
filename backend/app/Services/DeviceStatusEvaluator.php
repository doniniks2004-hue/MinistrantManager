<?php

namespace App\Services;

/**
 * Framework-free (spec review point 3): picks the PLATFORM-SPECIFIC
 * minimum supported version and decides the device's authoritative
 * status. Extracted out of DeviceController specifically so this decision
 * — which was the actual bug in Iteration 1 (comparing against a version
 * key nothing ever wrote) — can be unit tested without Eloquent/Laravel.
 * See /standalone-tests/test_device_status_evaluator.php.
 */
class DeviceStatusEvaluator
{
    /**
     * @return array{state: string, minimum_supported_app_version: ?string}
     */
    public static function evaluate(
        string $platform,
        ?string $appVersion,
        bool $deviceRevoked,
        bool $parishActive,
        ?string $minVersionAndroid,
        ?string $minVersionIos,
    ): array {
        $minVersion = match ($platform) {
            'android' => $minVersionAndroid,
            'ios' => $minVersionIos,
            default => null,
        };

        if ($deviceRevoked) {
            $state = 'DEVICE_REVOKED';
        } elseif (!$parishActive) {
            $state = 'PARISH_DISABLED';
        } elseif ($minVersion !== null && $appVersion !== null && version_compare($appVersion, $minVersion, '<')) {
            $state = 'UPDATE_REQUIRED';
        } else {
            $state = 'ACTIVE';
        }

        return ['state' => $state, 'minimum_supported_app_version' => $minVersion];
    }
}
