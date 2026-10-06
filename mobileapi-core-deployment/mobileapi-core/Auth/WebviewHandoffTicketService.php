<?php

namespace MinistrantManager\MobileAPI\Auth;

/**
 * Hybrid dashboard milestone (review round, point 18): mints and
 * consumes short-lived, single-use tickets that let an ALREADY mobile-
 * authenticated user open a legacy PHP module in a WebView without a
 * second login. See migrations/003_webview_handoff_tickets.sql.
 *
 * Deliberately NOT a re-encoding of mobile_user_token — the ticket
 * authorizes exactly one thing (loading `targetPath` once, within
 * `ttlSeconds`), never acts as a general bearer credential, and is
 * never valid a second time even if intercepted.
 */
class WebviewHandoffTicketService
{
    private const TTL_SECONDS = 60;

    public function __construct(private \mysqli $conn)
    {
    }

    /**
     * @param string $targetPath MUST already be validated against the
     *   caller's own allowlist (see webview_handoff.php) — this service
     *   does not know which paths are legitimate for this parish.
     */
    public function mint(int $userId, string $installationId, string $targetPath): array
    {
        $ticket = bin2hex(random_bytes(32));
        $expiresAt = date('Y-m-d H:i:s', time() + self::TTL_SECONDS);

        $stmt = $this->conn->prepare(
            'INSERT INTO webview_handoff_tickets (ticket, user_id, installation_id, target_path, expires_at) VALUES (?, ?, ?, ?, ?)'
        );
        $stmt->bind_param('sisss', $ticket, $userId, $installationId, $targetPath, $expiresAt);
        $stmt->execute();
        $stmt->close();

        return ['ticket' => $ticket, 'expires_at' => $expiresAt];
    }

    /**
     * Atomically consumes a ticket — the `UPDATE ... WHERE used_at IS
     * NULL` is what makes this genuinely single-use even under a race
     * (two near-simultaneous requests with the same ticket): only ONE
     * of them can ever see `affected_rows === 1`.
     *
     * Returns the ticket's row (user_id, installation_id, target_path)
     * on success, or null if the ticket doesn't exist, is expired, or
     * was already used.
     */
    public function consume(string $ticket): ?array
    {
        $stmt = $this->conn->prepare(
            'SELECT id, user_id, installation_id, target_path, expires_at, used_at FROM webview_handoff_tickets WHERE ticket = ?'
        );
        $stmt->bind_param('s', $ticket);
        $stmt->execute();
        $id = null;
        $userId = null;
        $installationId = null;
        $targetPath = null;
        $expiresAt = null;
        $usedAt = null;
        $stmt->bind_result($id, $userId, $installationId, $targetPath, $expiresAt, $usedAt);
        $hasRow = $stmt->fetch();
        $stmt->close();
        $row = $hasRow ? [
            'id' => $id,
            'user_id' => $userId,
            'installation_id' => $installationId,
            'target_path' => $targetPath,
            'expires_at' => $expiresAt,
            'used_at' => $usedAt,
        ] : null;

        if ($row === null) {
            return null;
        }
        if ($row['used_at'] !== null) {
            return null;
        }
        if (strtotime($row['expires_at']) < time()) {
            return null;
        }

        $stmt = $this->conn->prepare(
            'UPDATE webview_handoff_tickets SET used_at = NOW() WHERE id = ? AND used_at IS NULL'
        );
        $ticketId = (int) $row['id'];
        $stmt->bind_param('i', $ticketId);
        $stmt->execute();
        $consumed = $stmt->affected_rows === 1;
        $stmt->close();

        if (!$consumed) {
            // Lost the race to a concurrent consume() call — never valid twice.
            return null;
        }

        return [
            'user_id' => (int) $row['user_id'],
            'installation_id' => $row['installation_id'],
            'target_path' => $row['target_path'],
        ];
    }
}
