<?php

namespace MinistrantManager\MobileAPI\Auth;

use mysqli;
use MinistrantManager\MobileAPI\DTO\UserContext;

/**
 * Mints, validates, and revokes `mobile_user_tokens` rows (migration 001).
 * Deliberately plain mysqli, no framework — this runs INSIDE each
 * parish's existing plain-PHP codebase (Iteration 2 point 2: "Nie
 * instalujemy Laravela w parafiach").
 *
 * Token format: 32 random bytes, base64url-encoded, returned to the
 * client EXACTLY ONCE (at mint time) — only its Argon2id hash is ever
 * persisted, same pattern as admin_recovery_codes on app.ministrant.eu
 * (Iteration 1).
 */
final class MobileUserTokenService
{
    public function __construct(private readonly mysqli $conn)
    {
    }

    /**
     * Issues a fresh token for (userId, installationId), replacing any
     * existing one for that exact pair (rotation, not accumulation — see
     * migration 001's UNIQUE KEY). Returns the RAW token — the only time
     * it ever exists outside this function's local scope.
     */
    public function mint(int $userId, string $installationId): string
    {
        $raw = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
        $hash = password_hash($raw, PASSWORD_ARGON2ID);

        // Review round fix: ON DUPLICATE KEY now also overwrites user_id
        // (migration 001's UNIQUE key is on installation_id alone) — a
        // different user logging in on a device that was previously
        // someone else's atomically replaces the previous holder, who is
        // immediately locked out, rather than the two accounts both
        // having a live token at once.
        $stmt = $this->conn->prepare(
            'INSERT INTO mobile_user_tokens (user_id, installation_id, token_hash, created_at)
             VALUES (?, ?, ?, NOW())
             ON DUPLICATE KEY UPDATE
                user_id = VALUES(user_id),
                token_hash = VALUES(token_hash),
                created_at = NOW(),
                last_used_at = NULL,
                revoked_at = NULL'
        );
        $stmt->bind_param('iss', $userId, $installationId, $hash);
        $stmt->execute();
        $stmt->close();

        return $raw;
    }

    /**
     * Validates a raw bearer token against installation_id, returning the
     * UserContext it resolves to, or null if invalid/revoked/unknown.
     *
     * Deliberately looks up candidate rows by installation_id FIRST (an
     * indexed column — see migration 001) rather than scanning every
     * token row and hashing the input against each one; there is at most
     * one live row per (user, installation_id) by construction, and in
     * practice exactly one per installation_id at a time (one user
     * "signed in" per device), so this is a single indexed lookup plus
     * one password_verify() call, not O(all tokens).
     */
    public function validate(string $rawToken, string $installationId): ?UserContext
    {
        $stmt = $this->conn->prepare(
            'SELECT t.id, t.user_id, t.token_hash, u.role_id, r.name AS role_name,
                    u.parent_id, u.can_request_substitution, u.can_accept_substitution, u.is_active
             FROM mobile_user_tokens t
             JOIN users u ON u.id = t.user_id
             LEFT JOIN roles r ON r.id = u.role_id
             WHERE t.installation_id = ? AND t.revoked_at IS NULL'
        );
        $stmt->bind_param('s', $installationId);
        $stmt->execute();
        $result = $stmt->get_result();
        $row = $result->fetch_assoc();
        $stmt->close();

        if ($row === null) {
            return null;
        }

        if (!password_verify($rawToken, $row['token_hash'])) {
            return null;
        }

        if ((int) $row['is_active'] !== 1) {
            // Account deactivated on the parish side since the token was
            // minted — fail closed, same principle as app.ministrant.eu's
            // device-status checks (Iteration 1 review): a stored
            // credential is never enough on its own once the account it
            // belongs to is no longer active.
            return null;
        }

        $this->touchLastUsed((int) $row['id']);

        return new UserContext(
            userId: (int) $row['user_id'],
            roleId: (int) $row['role_id'],
            roleName: $row['role_name'] ?? 'unknown',
            parentId: $row['parent_id'] !== null ? (int) $row['parent_id'] : null,
            canRequestSubstitution: (bool) $row['can_request_substitution'],
            canAcceptSubstitution: (bool) $row['can_accept_substitution'],
        );
    }

    /**
     * Review point 4: "zaprojektuj mobile_user_tokens tak, żeby
     * installation_id było pierwszorzędnym elementem relacji i żeby można
     * było łatwo zrobić revoke all tokens WHERE installation_id = X."
     * This IS that operation — the eventual app.ministrant.eu revoke
     * webhook (once its exact contract is designed) calls exactly this.
     */
    public function revokeAllForInstallation(string $installationId): int
    {
        $stmt = $this->conn->prepare(
            'UPDATE mobile_user_tokens SET revoked_at = NOW()
             WHERE installation_id = ? AND revoked_at IS NULL'
        );
        $stmt->bind_param('s', $installationId);
        $stmt->execute();
        $affected = $stmt->affected_rows;
        $stmt->close();

        return $affected;
    }

    private function touchLastUsed(int $tokenId): void
    {
        $stmt = $this->conn->prepare('UPDATE mobile_user_tokens SET last_used_at = NOW() WHERE id = ?');
        $stmt->bind_param('i', $tokenId);
        $stmt->execute();
        $stmt->close();
    }
}
