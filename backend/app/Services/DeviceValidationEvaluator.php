<?php

namespace App\Services;

/**
 * Device-control-plane milestone. Framework-free (same reasoning as
 * DeviceStatusEvaluator — unit-testable without Eloquent/Laravel, see
 * /standalone-tests/test_device_validation_evaluator.php) decision logic
 * for `POST /internal/mobile/device/validate`.
 *
 * This is the single place that decides between the 5 states the parish
 * MobileAPI needs to distinguish (review round): active, revoked,
 * parish_disabled, not_found, parish_mismatch.
 */
class DeviceValidationEvaluator
{
    /**
     * @param array{parish_id: int, status: string}|null $device null if
     *   no MobileDevice row exists for the given installation_id at all.
     * @param int $requestingParishId the parish_id the CALLER authenticated
     *   as (via their own mobile_internal_api_secret) — never trust a
     *   parish_id supplied only in the request body without this.
     * @param bool $requestingParishActive whether the CALLING parish
     *   itself is active — a disabled parish shouldn't be able to
     *   validate ANY device, including its own, once disabled.
     * @param int $offlineLeaseHours the CALLING parish's own
     *   effectiveOfflineLeaseHours() — review round (follow-up fix):
     *   returned alongside the state so the parish's own
     *   DeviceAuthorizationService can cap how long it may keep trusting
     *   a STALE cached 'active' answer during a central outage, tied to
     *   the SAME policy that already governs how long the Flutter app
     *   itself may run offline — never a third, independently-invented
     *   duration.
     *
     * @return array{state: string, offline_lease_hours: int}
     */
    public static function evaluate(
        ?array $device,
        int $requestingParishId,
        bool $requestingParishActive,
        int $offlineLeaseHours,
    ): array {
        if (!$requestingParishActive) {
            return ['state' => 'parish_disabled', 'offline_lease_hours' => $offlineLeaseHours];
        }

        if ($device === null) {
            return ['state' => 'not_found', 'offline_lease_hours' => $offlineLeaseHours];
        }

        if ((int) $device['parish_id'] !== $requestingParishId) {
            // Review round: "Nie opieraj bezpieczeństwa na hostname
            // przesłanym przez klienta" — this is exactly that check,
            // done server-side against the authenticated identity (the
            // secret that resolved to $requestingParishId), never
            // against anything the caller merely CLAIMS.
            return ['state' => 'parish_mismatch', 'offline_lease_hours' => $offlineLeaseHours];
        }

        if ($device['status'] === 'revoked') {
            return ['state' => 'revoked', 'offline_lease_hours' => $offlineLeaseHours];
        }

        return ['state' => 'active', 'offline_lease_hours' => $offlineLeaseHours];
    }
}
