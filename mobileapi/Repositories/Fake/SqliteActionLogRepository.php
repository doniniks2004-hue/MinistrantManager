<?php

namespace MinistrantManager\MobileAPI\Repositories\Fake;

use MinistrantManager\MobileAPI\Contracts\ActionLogRepositoryInterface;

/**
 * TEST IMPLEMENTATION ONLY, but unlike FakeActionLogRepository this one
 * is backed by a REAL, shared SQLite file — on purpose, so it can be
 * exercised by two REAL, separate OS processes for a genuine concurrency
 * proof (see Tests/ActionIdempotencyConcurrencyTest.php). An in-memory
 * PHP array cannot race across processes; this can.
 *
 * Review round 2, point 3: this uses the EXACT SAME column shape as the
 * production migration (xxxx_xx_xx_create_mobile_action_log_table.php) —
 * parish_id, status (processing/completed/failed), nullable result_json,
 * claimed_at/finalized_at/failed_at — specifically so a passing test here
 * proves something about the real schema, not a divergent test-only one.
 *
 * tryClaim() reads-then-conditionally-writes inside `BEGIN IMMEDIATE`:
 * SQLite's write-lock acquisition at that point is what makes the whole
 * "check existing status/staleness, then insert-or-update" sequence
 * atomic — structurally the same guarantee a real production adapter
 * gets from `SELECT ... FOR UPDATE` in a transaction.
 */
class SqliteActionLogRepository implements ActionLogRepositoryInterface
{
    private \PDO $pdo;

    public function __construct(string $dbPath)
    {
        $this->pdo = new \PDO("sqlite:$dbPath");
        $this->pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        $this->pdo->exec('PRAGMA busy_timeout = 5000;');
    }

    public static function createSchema(string $dbPath): void
    {
        $pdo = new \PDO("sqlite:$dbPath");
        $pdo->exec('CREATE TABLE IF NOT EXISTS mobile_action_log (
            client_action_id TEXT PRIMARY KEY,
            parish_id TEXT,
            type TEXT,
            status TEXT,
            result_json TEXT,
            claimed_at INTEGER,
            finalized_at INTEGER,
            failed_at INTEGER
        )');
    }

    public function findResult(string $clientActionId): ?array
    {
        $stmt = $this->pdo->prepare('SELECT status, result_json FROM mobile_action_log WHERE client_action_id = ?');
        $stmt->execute([$clientActionId]);
        $row = $stmt->fetch(\PDO::FETCH_ASSOC);

        if (!$row || $row['status'] !== 'completed') {
            return null;
        }
        return json_decode($row['result_json'], true);
    }

    public function tryClaim(string $clientActionId, string $type, string $parishId, int $staleAfterSeconds = 30): bool
    {
        $now = time();

        try {
            $this->pdo->exec('BEGIN IMMEDIATE');

            $stmt = $this->pdo->prepare('SELECT status, claimed_at FROM mobile_action_log WHERE client_action_id = ?');
            $stmt->execute([$clientActionId]);
            $existing = $stmt->fetch(\PDO::FETCH_ASSOC);

            if ($existing === false) {
                $ins = $this->pdo->prepare(
                    'INSERT INTO mobile_action_log (client_action_id, parish_id, type, status, result_json, claimed_at) '
                    . 'VALUES (?, ?, ?, ?, NULL, ?)'
                );
                $ins->execute([$clientActionId, $parishId, $type, 'processing', $now]);
                $this->pdo->exec('COMMIT');
                return true;
            }

            $reclaimable = $existing['status'] === 'failed'
                || ($existing['status'] === 'processing' && ($now - (int) $existing['claimed_at']) >= $staleAfterSeconds);

            if (!$reclaimable) {
                $this->pdo->exec('COMMIT'); // nothing changes — release the write lock we took above
                return false;
            }

            $upd = $this->pdo->prepare(
                'UPDATE mobile_action_log SET parish_id = ?, type = ?, status = ?, result_json = NULL, '
                . 'claimed_at = ?, finalized_at = NULL, failed_at = NULL WHERE client_action_id = ?'
            );
            $upd->execute([$parishId, $type, 'processing', $now, $clientActionId]);
            $this->pdo->exec('COMMIT');
            return true;
        } catch (\PDOException $e) {
            try {
                $this->pdo->exec('ROLLBACK');
            } catch (\Throwable $ignored) {
            }
            return false;
        }
    }

    public function finalize(string $clientActionId, array $result): void
    {
        $stmt = $this->pdo->prepare('UPDATE mobile_action_log SET status = ?, result_json = ?, finalized_at = ? WHERE client_action_id = ?');
        $stmt->execute(['completed', json_encode($result), time(), $clientActionId]);
    }

    public function failClaim(string $clientActionId, string $reason): void
    {
        $stmt = $this->pdo->prepare('UPDATE mobile_action_log SET status = ?, result_json = ?, failed_at = ? WHERE client_action_id = ?');
        $stmt->execute(['failed', json_encode(['status' => 'error', 'reason' => $reason]), time(), $clientActionId]);
    }

    /** Test helper — directly backdates claimed_at for a stale-claim test, no sleeping required. */
    public function backdateClaim(string $clientActionId, int $secondsAgo): void
    {
        $stmt = $this->pdo->prepare('UPDATE mobile_action_log SET claimed_at = ? WHERE client_action_id = ?');
        $stmt->execute([time() - $secondsAgo, $clientActionId]);
    }
}
