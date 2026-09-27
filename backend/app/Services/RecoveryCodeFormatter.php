<?php

namespace App\Services;

/**
 * Pure, framework-free half of recovery-code handling: generation format,
 * normalization, and hashing. Split out from RecoveryCodeService (which
 * needs Eloquent to persist/query AdminRecoveryCode rows) specifically so
 * this part can be unit tested without booting the framework — see
 * /standalone-tests/test_recovery_code_formatter.php.
 *
 * Iteration 1.1 point 10 fix: was plain SHA-256 (fast by design — wrong
 * property for a secret an attacker might try to brute-force offline if
 * the DB ever leaks). Now Argon2id via PHP's native password_hash()/
 * password_verify() — no Laravel Hash facade dependency, so this stays
 * framework-free and testable. At most 10 codes per admin, so iterating
 * unused hashes with password_verify() (which can't be looked up by exact
 * value like SHA-256 could) is cheap — see RecoveryCodeService::attemptConsume().
 */
class RecoveryCodeFormatter
{
    private const ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ'; // no 0/O/1/I/L

    public static function generateOne(): string
    {
        $raw = '';
        for ($i = 0; $i < 12; $i++) {
            $raw .= self::ALPHABET[random_int(0, strlen(self::ALPHABET) - 1)];
        }
        return implode('-', str_split($raw, 4)); // "7KMF-92QX-P4DT"
    }

    /**
     * Stable regardless of how the admin re-types the code back (case,
     * dashes, stray spaces all normalized away first) — applied before
     * both hashForStorage() and verify() so they always agree.
     */
    public static function normalize(string $rawCode): string
    {
        return strtoupper(preg_replace('/[^A-Za-z0-9]/', '', $rawCode));
    }

    public static function hashForStorage(string $rawCode): string
    {
        return password_hash(self::normalize($rawCode), PASSWORD_ARGON2ID);
    }

    public static function verify(string $rawCode, string $storedHash): bool
    {
        return password_verify(self::normalize($rawCode), $storedHash);
    }
}
