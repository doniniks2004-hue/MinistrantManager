<?php

namespace MinistrantManager\MobileAPI\Middleware;

/**
 * Outcome of verifying a device token against the CURRENT parish subdomain
 * the request came in on (spec §8/§36 — TENANT_MISMATCH). `ok` is false
 * for every failure mode; `code` distinguishes WHY, since the client and
 * the mobile app's RevocationHandler react differently to each:
 *   - MISSING_TOKEN / INVALID_TOKEN -> not activated / activation broken
 *   - DEVICE_REVOKED -> wipe local data, return to activation
 *   - PARISH_DISABLED -> wipe local data, return to activation
 *   - TENANT_MISMATCH -> token belongs to a DIFFERENT parish than this
 *     subdomain — never wipe data (it's not this device's data to wipe),
 *     just refuse the request. This is the spec §36 isolation test.
 */
final class DeviceAuthResult
{
    private function __construct(
        public readonly bool $ok,
        public readonly ?string $code = null,
        public readonly ?string $parishId = null,
    ) {
    }

    public static function ok(string $parishId): self
    {
        return new self(true, parishId: $parishId);
    }

    public static function fail(string $code): self
    {
        return new self(false, code: $code);
    }

    public function httpStatus(): int
    {
        return match ($this->code) {
            'TENANT_MISMATCH' => 403,
            'DEVICE_REVOKED', 'PARISH_DISABLED' => 403,
            default => 401,
        };
    }
}
