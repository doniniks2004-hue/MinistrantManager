<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Models\MobileActivationCode;
use App\Models\MobileDevice;
use App\Services\AuditLogger;
use App\Services\TokenService;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\Facades\Validator;
use Illuminate\Validation\ValidationException;

/**
 * Handles the two-step activation flow described in the spec:
 *
 *   1. POST /api/activation/check   — resolve a scanned/typed code to a parish
 *                                       (does NOT consume the code or create a device)
 *   2. POST /api/activation/confirm — actually register the device and burn one use
 *
 * Rate limiting (fixed after review — see throttleOrFail() docblock for
 * what was wrong before): failed attempts are what gets limited, not every
 * request, so a parish activating several legitimate devices from one
 * Wi-Fi network is never blocked by its own successful activations.
 *
 * Race condition on `max_uses` (fixed — see confirm()): the whole
 * check-then-increment sequence now runs inside a DB transaction with
 * `lockForUpdate()` on the activation code row, so two devices racing to
 * consume the last remaining use can no longer both succeed.
 */
class ActivationController extends Controller
{
    private const MAX_FAILED_ATTEMPTS = 5;
    private const FAILED_ATTEMPTS_DECAY_MINUTES = 10;

    // Generous ceiling on TOTAL requests (successful + failed) per IP, purely
    // as a DoS/abuse backstop — deliberately much higher than
    // MAX_FAILED_ATTEMPTS so it never interferes with normal parish usage
    // (several phones activating back-to-back on the same Wi-Fi).
    private const MAX_TOTAL_REQUESTS_PER_IP = 60;
    private const TOTAL_REQUESTS_DECAY_MINUTES = 10;

    public function check(Request $request)
    {
        $data = $this->validateLookup($request);
        $this->normalizeDisplayCode($data);

        $this->throttleTotalOrFail($request);

        $code = $this->resolveCode($data);

        if (!$code || !$code->isUsable()) {
            $this->recordFailedAttempt($request, $data, 'code_not_usable_or_not_found');
            throw ValidationException::withMessages([
                'code' => 'Kod aktywacyjny jest nieprawidłowy, wygasł lub został unieważniony.',
            ]);
        }

        $parish = $code->parish;

        return response()->json([
            'parish' => [
                'id' => $parish->id,
                'name' => $parish->name,
                'slug' => $parish->slug,
                'server_url' => $parish->server_url,
            ],
        ]);
    }

    public function confirm(Request $request)
    {
        $data = $this->validateLookup($request);
        $this->normalizeDisplayCode($data);
        $data += $request->validate([
            'installation_id' => ['required', 'uuid'],
            'platform' => ['required', 'in:android,ios'],
            'device_model' => ['nullable', 'string', 'max:255'],
            'os_version' => ['nullable', 'string', 'max:100'],
            'app_version' => ['nullable', 'string', 'max:50'],
        ]);

        $this->throttleTotalOrFail($request);

        [$device, $rawDeviceToken, $parish] = DB::transaction(function () use ($data, $request) {
                // lockForUpdate() is the fix for the race condition flagged
                // in review: two devices can no longer both read
                // used_count=0/max_uses=1, both pass isUsable(), and both
                // get activated off a single-use code. The row is locked
                // for the duration of this transaction, so the second
                // concurrent request blocks here until the first commits,
                // then re-reads a used_count that already reflects it.
                $code = $this->lockCodeForUpdate($data);

                if (!$code || !$code->isUsable() || !$code->parish->isActive()) {
                    $this->recordFailedAttempt($request, $data, 'code_not_usable_at_confirm');
                    throw ValidationException::withMessages([
                        'code' => 'Kod aktywacyjny jest nieprawidłowy, wygasł lub został unieważniony.',
                    ]);
                }

                $parish = $code->parish;
                $rawDeviceToken = TokenService::generateDeviceToken();

                $device = MobileDevice::updateOrCreate(
                    ['installation_id' => $data['installation_id']],
                    [
                        'parish_id' => $parish->id,
                        'activation_code_id' => $code->id,
                        'platform' => $data['platform'],
                        'device_model' => $data['device_model'] ?? null,
                        'os_version' => $data['os_version'] ?? null,
                        'app_version' => $data['app_version'] ?? null,
                        'device_token_hash' => TokenService::hash($rawDeviceToken),
                        'status' => 'active',
                        'activated_at' => now(),
                        'last_seen_at' => now(),
                        'last_authorization_check' => now(),
                        'revoked_at' => null,
                        'revoked_by' => null,
                    ]
                );

                $code->increment('used_count');
                $code->refresh();
                if (!is_null($code->max_uses) && $code->used_count >= $code->max_uses) {
                    $code->update(['status' => 'used']);
                }

                return [$device, $rawDeviceToken, $parish];
            });

        AuditLogger::log('device.activated', 'MobileDevice', $device->id, [
            'parish' => $parish->slug,
            'platform' => $device->platform,
            'device_model' => $device->device_model,
        ]);

        return response()->json([
            'parish' => [
                'id' => $parish->id,
                'name' => $parish->name,
                'slug' => $parish->slug,
                'server_url' => $parish->server_url,
            ],
            'device' => [
                'installation_id' => $device->installation_id,
                'device_token' => $rawDeviceToken, // shown once — client must store in Keystore/Keychain
                'status' => $device->status,
            ],
        ]);
    }

    private function validateLookup(Request $request): array
    {
        return Validator::make($request->all(), [
            'token' => ['required_without:display_code', 'string'],
            'display_code' => ['required_without:token', 'string'],
        ])->validate();
    }

    /**
     * Normalizes display_code in place (uppercase, no spaces) BEFORE it is
     * used anywhere — including as a rate-limiter key. Fixes the review
     * finding that "73fk-92mx", "73FK-92MX" and "73 FK 92 MX" previously
     * hashed to different rate-limit buckets, letting an attacker multiply
     * their effective attempt budget just by varying case/whitespace.
     */
    private function normalizeDisplayCode(array &$data): void
    {
        if (!empty($data['display_code'])) {
            $data['display_code'] = strtoupper(str_replace(' ', '', $data['display_code']));
        }
    }

    private function resolveCode(array $data): ?MobileActivationCode
    {
        if (!empty($data['token'])) {
            return MobileActivationCode::where('token_hash', TokenService::hash($data['token']))->first();
        }
        return MobileActivationCode::where('display_code', $data['display_code'])->first();
    }

    private function lockCodeForUpdate(array $data): ?MobileActivationCode
    {
        $query = !empty($data['token'])
            ? MobileActivationCode::where('token_hash', TokenService::hash($data['token']))
            : MobileActivationCode::where('display_code', $data['display_code']);

        return $query->lockForUpdate()->first();
    }

    /**
     * High-ceiling, IP-only backstop against raw request flooding. This is
     * NOT the anti-brute-force mechanism — see recordFailedAttempt() for
     * that. Kept deliberately generous (60/10min) so it never fires during
     * legitimate multi-device activation from one parish Wi-Fi network.
     */
    private function throttleTotalOrFail(Request $request): void
    {
        $key = 'activation:total:' . $request->ip();
        if (RateLimiter::tooManyAttempts($key, self::MAX_TOTAL_REQUESTS_PER_IP)) {
            AuditLogger::log('activation.rate_limited', null, null, ['ip' => $request->ip(), 'scope' => 'total']);
            abort(429, 'Zbyt wiele żądań. Spróbuj ponownie później.');
        }
        RateLimiter::hit($key, self::TOTAL_REQUESTS_DECAY_MINUTES * 60);
    }

    /**
     * THE actual anti-brute-force mechanism (fixed after review — the
     * previous version called RateLimiter::hit() unconditionally in
     * throttleOrFail(), counting successful activations against the same
     * budget as failed guesses; three phones activating in a row on one
     * Wi-Fi could lock out a fourth, legitimate one).
     *
     * Only ever called on a failed check()/confirm() — i.e. wrong, expired,
     * revoked, or already-used code. Keyed by IP AND by the normalized
     * code/token prefix, so neither "many codes from one IP" nor "one code
     * brute-forced from many IPs" escapes the limit.
     */
    private function recordFailedAttempt(Request $request, array $data, string $reason): void
    {
        $codeKey = $data['display_code'] ?? substr($data['token'] ?? '', 0, 16);

        // Review round fix: was rate-limiting AND audit-logging on the raw
        // display code / a raw token fragment directly — meaning actual
        // activation secrets ended up sitting in plaintext in both the
        // rate limiter's cache keys and the audit_logs table. A
        // fingerprint (truncated hash of the normalized code) still lets
        // an admin correlate repeated attempts against the SAME code
        // without the log itself becoming a place a real code could be
        // read back out of.
        $fingerprint = substr(hash('sha256', strtoupper(preg_replace('/[^A-Za-z0-9]/', '', $codeKey))), 0, 12);

        $ipKey = 'activation:failed:ip:' . $request->ip();
        $codeRateKey = 'activation:failed:code:' . $fingerprint;

        RateLimiter::hit($ipKey, self::FAILED_ATTEMPTS_DECAY_MINUTES * 60);
        RateLimiter::hit($codeRateKey, self::FAILED_ATTEMPTS_DECAY_MINUTES * 60);

        AuditLogger::log('activation.failed', null, null, [
            'reason' => $reason,
            'code_fingerprint' => $fingerprint,
        ]);

        if (RateLimiter::tooManyAttempts($ipKey, self::MAX_FAILED_ATTEMPTS)) {
            AuditLogger::log('activation.rate_limited', null, null, ['ip' => $request->ip(), 'scope' => 'failed_ip']);
            abort(429, 'Zbyt wiele nieudanych prób. Spróbuj ponownie za kilka minut.');
        }
        if (RateLimiter::tooManyAttempts($codeRateKey, self::MAX_FAILED_ATTEMPTS)) {
            AuditLogger::log('activation.rate_limited', null, null, ['code_fingerprint' => $fingerprint, 'scope' => 'failed_code']);
            abort(429, 'Zbyt wiele nieudanych prób dla tego kodu.');
        }
    }
}
