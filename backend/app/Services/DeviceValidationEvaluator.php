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
     *
     * @return array{state: string}
     */
    public static function evaluate(
        ?array $device,
        int $requestingParishId,
        bool $requestingParishActive,
    ): array {
        if (!$requestingParishActive) {
            return ['state' => 'parish_disabled'];
        }

        if ($device === null) {
            return ['state' => 'not_found'];
        }

        if ((int) $device['parish_id'] !== $requestingParishId) {
            // Review round: "Nie opieraj bezpieczeństwa na hostname
            // przesłanym przez klienta" — this is exactly that check,
            // done server-side against the authenticated identity (the
            // secret that resolved to $requestingParishId), never
            // against anything the caller merely CLAIMS.
            return ['state' => 'parish_mismatch'];
        }

        if ($device['status'] === 'revoked') {
            return ['state' => 'revoked'];
        }

        return ['state' => 'active'];
    }
}
