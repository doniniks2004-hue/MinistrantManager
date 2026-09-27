<?php

namespace MinistrantManager\MobileAPI\Contracts;

/**
 * What VerifyDeviceTokenService needs to know about a device token,
 * without caring HOW it's verified (locally against a synced copy of
 * app.ministrant.eu's device table, or via a live HTTP call to
 * app.ministrant.eu/api/device/status — see MobileAPI's docs/INTEGRATION.md
 * for the tradeoffs). Returns null for an unknown/invalid token.
 */
interface DeviceTokenStoreInterface
{
    /**
     * @return array{parish_id: string, status: string, parish_status: string}|null
     *   status: "active"|"revoked" (the DEVICE's own status)
     *   parish_status: "active"|"disabled" (the device's PARISH's status)
     */
    public function lookup(string $rawDeviceToken): ?array;
}
