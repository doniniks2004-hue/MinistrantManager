<?php

namespace MinistrantManager\MobileAPI\Auth;

use mysqli;

/**
 * Device-control-plane milestone (review round). The ONE place every
 * parish endpoint consults to answer "is this installation allowed to
 * use MobileAPI right now" — review round point 3: "Nie rozrzucaj
 * requestów do centrali po endpointach."
 *
 * `app.ministrant.eu` remains the ONLY source of truth (review round:
 * "Nie kopiujemy centralnej bazy urządzeń do parafii"). This class
 * caches only the last {state, checked_at} ANSWER for a short lease
 * (review round point 5: "krótki cache/autoryzacyjny lease... np.
 * kilka–kilkanaście minut" — chosen 10 minutes here), specifically so a
 * central outage doesn't take down every parish's login/handoff at
 * once, while still re-confirming with the real source of truth
 * frequently.
 *
 * Review round point 9 (offline-first): if central is unreachable and
 * we have NO prior cached answer, this returns 'central_unavailable' —
 * a DISTINCT state from 'revoked', so a caller never mistakes "we
 * couldn't check" for "we checked and it's bad". If central is
 * unreachable but we DO have a previous cached answer (even if its
 * lease expired), that last known state is returned with `stale: true`
 * — a genuine network hiccup must never suddenly act like a revoke.
 */
class DeviceAuthorizationService
{
    private const LEASE_SECONDS = 600; // 10 minutes
    private const HTTP_TIMEOUT_SECONDS = 5;

    public function __construct(
        private readonly mysqli $conn,
        private readonly string $centralBaseUrl,
        private readonly string $parishSecret,
    ) {
    }

    /**
     * @return array{state: string, stale: bool}
     */
    public function validate(string $installationId): array
    {
        $cached = $this->readCache($installationId);

        if ($cached !== null && strtotime($cached['expires_at']) > time()) {
            return ['state' => $cached['state'], 'stale' => false];
        }

        $fresh = $this->callCentral($installationId);

        if ($fresh !== null) {
            $this->writeCache($installationId, $fresh['state'], $fresh['offline_lease_hours']);
            return ['state' => $fresh['state'], 'stale' => false];
        }

        // Central unreachable (network error, timeout, non-200, malformed
        // response — all treated the same: "we couldn't get an answer").
        if ($cached !== null) {
            // Review round follow-up fix: a stale 'active' answer must
            // NOT be trustable forever just because central happens to
            // be down. Hard cap this at the SAME offline_lease_hours
            // policy that already governs how long the Flutter app
            // itself may run offline (returned by central alongside the
            // original answer, stored in this row) — never a third,
            // independently-invented duration. Once exceeded, this is
            // treated exactly like having no prior knowledge at all.
            $maxStaleSeconds = $cached['offline_lease_hours'] * 3600;
            $ageSeconds = time() - strtotime($cached['checked_at']);
            if ($ageSeconds > $maxStaleSeconds) {
                return ['state' => 'central_unavailable', 'stale' => true];
            }

            // A real, previously-confirmed answer exists, still within
            // its hard cap — a network hiccup right now must never
            // override it with something worse. This is what keeps an
            // already-active device working through a central outage
            // (review round point 9), for as long as the SAME offline
            // policy already allows.
            return ['state' => $cached['state'], 'stale' => true];
        }

        // No prior knowledge AND central unreachable — genuinely cannot
        // say either way. Never silently treated as 'active' (that would
        // defeat the entire point of this check) NOR as 'revoked' (that
        // would falsely punish a device for a central outage it had
        // nothing to do with).
        return ['state' => 'central_unavailable', 'stale' => true];
    }

    private function readCache(string $installationId): ?array
    {
        $stmt = $this->conn->prepare(
            'SELECT state, offline_lease_hours, checked_at, expires_at FROM device_authorization_cache WHERE installation_id = ?'
        );
        $stmt->bind_param('s', $installationId);
        $stmt->execute();
        $row = $stmt->get_result()->fetch_assoc();
        $stmt->close();

        return $row ?: null;
    }

    private function writeCache(string $installationId, string $state, int $offlineLeaseHours): void
    {
        $now = date('Y-m-d H:i:s');
        $expiresAt = date('Y-m-d H:i:s', time() + self::LEASE_SECONDS);

        $stmt = $this->conn->prepare(
            'INSERT INTO device_authorization_cache (installation_id, state, offline_lease_hours, checked_at, expires_at)
             VALUES (?, ?, ?, ?, ?)
             ON DUPLICATE KEY UPDATE state = VALUES(state), offline_lease_hours = VALUES(offline_lease_hours),
                checked_at = VALUES(checked_at), expires_at = VALUES(expires_at)'
        );
        $stmt->bind_param('ssiss', $installationId, $state, $offlineLeaseHours, $now, $expiresAt);
        $stmt->execute();
        $stmt->close();
    }

    /**
     * @return array{state: string, offline_lease_hours: int}|null null
     *   means "couldn't get a real answer" (network error, timeout,
     *   non-2xx, or a response we can't parse) — the caller decides what
     *   to do about that, this method never guesses.
     */
    private function callCentral(string $installationId): ?array
    {
        $url = rtrim($this->centralBaseUrl, '/') . '/api/internal/mobile/device/validate';
        $payload = json_encode(['installation_id' => $installationId], JSON_UNESCAPED_SLASHES);

        $body = false;
        $statusCode = 0;

        // Prefer cURL when available. Shared-hosting PHP profiles do not
        // always ship ext-curl, so its absence must NOT turn parish login
        // into HTTP 500.
        if (function_exists('curl_init')) {
            $ch = curl_init($url);
            if ($ch !== false) {
                curl_setopt_array($ch, [
                    CURLOPT_RETURNTRANSFER => true,
                    CURLOPT_POST => true,
                    CURLOPT_POSTFIELDS => $payload,
                    CURLOPT_HTTPHEADER => [
                        'Content-Type: application/json',
                        'Authorization: Bearer ' . $this->parishSecret,
                    ],
                    CURLOPT_TIMEOUT => self::HTTP_TIMEOUT_SECONDS,
                    CURLOPT_CONNECTTIMEOUT => self::HTTP_TIMEOUT_SECONDS,
                ]);

                $body = curl_exec($ch);
                $statusCode = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
                curl_close($ch);
            }
        } else {
            // Hostido-compatible fallback using PHP streams.
            $context = stream_context_create([
                'http' => [
                    'method' => 'POST',
                    'header' => "Content-Type: application/json\r\n"
                        . "Authorization: Bearer {$this->parishSecret}\r\n",
                    'content' => $payload,
                    'timeout' => self::HTTP_TIMEOUT_SECONDS,
                    'ignore_errors' => true,
                ],
                'ssl' => [
                    'verify_peer' => true,
                    'verify_peer_name' => true,
                ],
            ]);

            $body = @file_get_contents($url, false, $context);
            foreach (($http_response_header ?? []) as $header) {
                if (preg_match('/^HTTP\/\S+\s+(\d{3})/', $header, $m)) {
                    $statusCode = (int) $m[1];
                }
            }
        }

        if ($body === false || $statusCode !== 200) {
            return null;
        }

        $decoded = json_decode($body, true);
        if (!is_array($decoded) || !isset($decoded['state']) || !is_string($decoded['state'])) {
            return null;
        }

        $offlineLeaseHours = $decoded['offline_lease_hours'] ?? null;
        if (!is_int($offlineLeaseHours)) {
            // Defensive default matching Parish::effectiveOfflineLeaseHours()'s
            // own fallback — an older central version that doesn't send
            // this field yet must never crash this call, just fall back
            // to the same default central itself would use.
            $offlineLeaseHours = 72;
        }

        return ['state' => $decoded['state'], 'offline_lease_hours' => $offlineLeaseHours];
    }
}
