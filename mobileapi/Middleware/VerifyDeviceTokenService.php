<?php

namespace MinistrantManager\MobileAPI\Middleware;

use MinistrantManager\MobileAPI\Contracts\DeviceTokenStoreInterface;

/**
 * Framework-agnostic core of the `VerifyDeviceToken` middleware (spec §8).
 * The actual Laravel middleware (see VerifyDeviceToken.php in this same
 * folder) is a thin adapter that extracts the bearer token and the
 * current parish id from the request, then delegates the actual decision
 * here — which is what makes this class unit-testable without booting
 * Laravel (see Tests/VerifyDeviceTokenServiceTest.php).
 */
class VerifyDeviceTokenService
{
    public function __construct(private readonly DeviceTokenStoreInterface $tokenStore)
    {
    }

    /**
     * @param string $currentParishId the parish that OWNS the subdomain
     *   this request came in on (e.g. resolved from the Host header /
     *   tenant-resolution middleware that must run before this one)
     */
    public function verify(?string $rawToken, string $currentParishId): DeviceAuthResult
    {
        if ($rawToken === null || $rawToken === '') {
            return DeviceAuthResult::fail('MISSING_TOKEN');
        }

        $device = $this->tokenStore->lookup($rawToken);
        if ($device === null) {
            return DeviceAuthResult::fail('INVALID_TOKEN');
        }

        // THE critical check for spec §8/§36: a token issued for CHWK must
        // never authenticate a request against xyz.ministrant.eu, even
        // though the token itself is otherwise perfectly valid.
        if ($device['parish_id'] !== $currentParishId) {
            return DeviceAuthResult::fail('TENANT_MISMATCH');
        }

        if ($device['status'] === 'revoked') {
            return DeviceAuthResult::fail('DEVICE_REVOKED');
        }

        if ($device['parish_status'] === 'disabled') {
            return DeviceAuthResult::fail('PARISH_DISABLED');
        }

        return DeviceAuthResult::ok($device['parish_id']);
    }
}
