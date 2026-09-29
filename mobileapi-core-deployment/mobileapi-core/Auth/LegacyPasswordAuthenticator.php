<?php

namespace MinistrantManager\MobileAPI\Auth;

use mysqli;

/**
 * Iteration 2, review point 2 ("Bez duplikowania password/rate-limit
 * logic — wydziel wspólną funkcję/service ze starego auth"): this is
 * EXACTLY the verification half of Witosa's `src/auth.php` (username +
 * password + `login_attempts` rate limiting + timing-attack dummy hash),
 * extracted so `/mobile/session/login` and the existing web
 * `src/auth.php` can both call it, instead of the mobile endpoint
 * re-implementing its own copy.
 *
 * Deliberately does NOT touch $_SESSION, cookies, or issue a remember
 * token — those are `src/auth.php`'s own concerns for the web login path.
 * This class only answers one question: "is this username/password valid
 * for this parish's users table, and if so, which user?" — session/token
 * issuance is the caller's job (`api/mobile/session_login.php` mints a
 * mobile_user_token; the existing web login sets $_SESSION).
 *
 * NOT YET WIRED into src/auth.php itself — Iteration 2 point 2 also says
 * "nie przebudowuj istniejącego src/auth.php bardziej niż konieczne".
 * Swapping auth.php's inline duplicate of this logic for a call into this
 * class is a small, separate, easily-reviewable follow-up patch, not
 * bundled into this vertical slice.
 */
final class LegacyPasswordAuthenticator
{
    private const MAX_FAILED_ATTEMPTS = 5;
    private const DECAY_MINUTES = 15;

    public function __construct(private readonly mysqli $conn)
    {
    }

    /**
     * @return array{id:int, full_name:?string, role_id:int, is_active:bool}|null
     *   null means "invalid credentials OR rate-limited" — deliberately
     *   the same outward result for both, exactly like auth.php's
     *   existing behavior, so a client can't distinguish "wrong password"
     *   from "you're rate-limited" from response shape alone.
     */
    public function attempt(string $username, string $password, string $ip): ?array
    {
        if ($username === '' || $password === '' || strlen($username) > 50 || strlen($password) > 255) {
            return null;
        }

        if ($this->isRateLimited($ip, $username)) {
            return null;
        }

        // Dummy hash for timing-attack protection — verbatim from
        // auth.php: a fixed-cost password_verify() runs even when the
        // username doesn't exist, so response timing doesn't leak whether
        // a username is valid.
        $dummyHash = '$2y$12$' . str_repeat('a', 53);

        $stmt = $this->conn->prepare(
            'SELECT id, password, role_id, full_name, is_active FROM users WHERE username = ? LIMIT 1'
        );
        $stmt->bind_param('s', $username);
        $stmt->execute();
        $result = $stmt->get_result();
        $user = $result->fetch_assoc();
        $stmt->close();

        $hash = $user['password'] ?? $dummyHash;
        $isValid = password_verify($password, $hash);

        $this->recordAttempt($ip, $username, $isValid && $user !== null);

        if ($user === null || !$isValid || (int) $user['is_active'] !== 1) {
            return null;
        }

        return [
            'id' => (int) $user['id'],
            'full_name' => $user['full_name'],
            'role_id' => (int) $user['role_id'],
            'is_active' => true,
        ];
    }

    private function isRateLimited(string $ip, string $username): bool
    {
        if (!$this->loginAttemptsTableExists()) {
            return false; // same graceful degradation as auth.php: table optional
        }

        // Review round fix: was `COUNT(*)` over ALL attempts, successful
        // ones included — several legitimate logins from one office/parish
        // Wi-Fi IP could rate-limit the next real login for 15 minutes.
        // Only FAILED attempts count toward the limit now.
        $timeLimit = date('Y-m-d H:i:s', strtotime('-' . self::DECAY_MINUTES . ' minutes'));
        $stmt = $this->conn->prepare(
            'SELECT COUNT(*) AS attempts FROM login_attempts
             WHERE (ip_address = ? OR username = ?) AND was_successful = 0 AND attempt_time > ?'
        );
        $stmt->bind_param('sss', $ip, $username, $timeLimit);
        $stmt->execute();
        $attempts = (int) $stmt->get_result()->fetch_assoc()['attempts'];
        $stmt->close();

        return $attempts >= self::MAX_FAILED_ATTEMPTS;
    }

    private function recordAttempt(string $ip, string $username, bool $wasSuccessful): void
    {
        if (!$this->loginAttemptsTableExists()) {
            return;
        }

        $successFlag = $wasSuccessful ? 1 : 0;
        $stmt = $this->conn->prepare(
            'INSERT INTO login_attempts (ip_address, username, attempt_time, was_successful) VALUES (?, ?, NOW(), ?)'
        );
        $stmt->bind_param('ssi', $ip, $username, $successFlag);
        @$stmt->execute();
        $stmt->close();

        if ($wasSuccessful) {
            // Review round addition: a successful login resets this
            // username's slate — earlier failed attempts (someone's
            // mistyped password before they got it right, say) no longer
            // count toward the limit at all, matching "po prawidłowym
            // logowaniu wyczyść wcześniejsze błędne próby tego użytkownika".
            $stmt = $this->conn->prepare('DELETE FROM login_attempts WHERE username = ? AND was_successful = 0');
            $stmt->bind_param('s', $username);
            @$stmt->execute();
            $stmt->close();

            @$this->conn->query("DELETE FROM login_attempts WHERE attempt_time < DATE_SUB(NOW(), INTERVAL 1 DAY)");
        }
    }

    private function loginAttemptsTableExists(): bool
    {
        $result = @$this->conn->query("SHOW TABLES LIKE 'login_attempts'");
        return $result && $result->num_rows > 0;
    }
}
