<?php

namespace App\Services;

/**
 * Central place for generating and hashing every secret this system issues:
 * activation tokens and device tokens. We never store raw secrets — only
 * their SHA-256 hash. The raw value is shown to the admin / device exactly
 * once, at creation time.
 */
class TokenService
{
    /**
     * A long, cryptographically random token used as the *real* activation
     * secret embedded in the QR code (app.ministrant.eu/activate/{token}).
     * This is NOT the short human-typeable display code.
     */
    public static function generateActivationToken(): string
    {
        return bin2hex(random_bytes(32)); // 64 hex chars
    }

    /**
     * A short, human-typeable code for manual entry, e.g. "73FK-92MX".
     * Deliberately excludes ambiguous characters (0/O, 1/I).
     */
    public static function generateDisplayCode(): string
    {
        $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        $part = function () use ($alphabet) {
            $out = '';
            for ($i = 0; $i < 4; $i++) {
                $out .= $alphabet[random_int(0, strlen($alphabet) - 1)];
            }
            return $out;
        };

        return $part() . '-' . $part();
    }

    /**
     * A long, cryptographically random device token, issued once at
     * activation and stored by the client in Keystore/Keychain.
     */
    public static function generateDeviceToken(): string
    {
        return bin2hex(random_bytes(32));
    }

    public static function hash(string $rawToken): string
    {
        return hash('sha256', $rawToken);
    }
}
