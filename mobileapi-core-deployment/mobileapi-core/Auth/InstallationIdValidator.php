<?php

namespace MinistrantManager\MobileAPI\Auth;

/**
 * Iteration 2 review round, point 3: `/session/login` (and `/session/exchange`
 * once it exists) used to accept installation_id as an arbitrary string,
 * unvalidated. Minimum bar for now: well-formed UUID, non-empty, within
 * the `mobile_user_tokens.installation_id` column's VARCHAR(64) limit.
 *
 * Deliberately NOT checking here that this installation_id corresponds to
 * an actually-activated, non-revoked device on app.ministrant.eu — that
 * real cross-system check is explicitly deferred (review round: "Do
 * testowego vertical slice można to odłożyć, do produkcji nie").
 */
final class InstallationIdValidator
{
    private const MAX_LENGTH = 64;

    // Canonical UUID shape (any version/variant) — 8-4-4-4-12 hex digits.
    // The Flutter client generates these with the `uuid` package's v4()
    // (Iteration 1), which produces exactly this shape.
    private const PATTERN = '/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/';

    public static function isValid(string $installationId): bool
    {
        if ($installationId === '' || strlen($installationId) > self::MAX_LENGTH) {
            return false;
        }

        return preg_match(self::PATTERN, $installationId) === 1;
    }
}
