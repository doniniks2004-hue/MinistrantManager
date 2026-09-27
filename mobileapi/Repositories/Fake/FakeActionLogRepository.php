<?php

namespace MinistrantManager\MobileAPI\Repositories\Fake;

use MinistrantManager\MobileAPI\Contracts\ActionLogRepositoryInterface;

/**
 * TEST IMPLEMENTATION ONLY — per spec decision #7, never used in
 * production. In-memory, single-process — correctly models the sequential
 * (non-racing) tests in ActionDispatcherTest.php, including the stale/
 * failed-claim reclaim logic (review round 2, point 4), but does NOT
 * itself prove thread/process-safety. The actual concurrency proof for
 * tryClaim() lives in Tests/ActionIdempotencyConcurrencyTest.php against a
 * REAL shared SQLite file across two real OS processes — see
 * SqliteActionLogRepository, which implements this SAME contract/schema
 * shape (parish_id, status, nullable result_json, claimed_at) as the
 * production migration, per review round 2 point 3's explicit
 * requirement that the two never diverge.
 */
class FakeActionLogRepository implements ActionLogRepositoryInterface
{
    /** @var array<string, array{type:string, parishId:string, status:string, result:?array, claimedAt:\DateTimeImmutable}> */
    private array $log = [];

    public function findResult(string $clientActionId): ?array
    {
        $row = $this->log[$clientActionId] ?? null;
        if ($row === null || $row['status'] !== 'completed') {
            return null;
        }
        return $row['result'];
    }

    public function tryClaim(string $clientActionId, string $type, string $parishId, int $staleAfterSeconds = 30): bool
    {
        $existing = $this->log[$clientActionId] ?? null;

        if ($existing === null) {
            $this->claim($clientActionId, $type, $parishId);
            return true;
        }

        if ($existing['status'] === 'completed') {
            return false;
        }

        if ($existing['status'] === 'failed') {
            // Immediately reclaimable — a definitive failure signal.
            $this->claim($clientActionId, $type, $parishId);
            return true;
        }

        // status === 'processing': only reclaimable once genuinely stale.
        $ageSeconds = (new \DateTimeImmutable())->getTimestamp() - $existing['claimedAt']->getTimestamp();
        if ($ageSeconds >= $staleAfterSeconds) {
            $this->claim($clientActionId, $type, $parishId);
            return true;
        }

        return false;
    }

    public function finalize(string $clientActionId, array $result): void
    {
        $this->log[$clientActionId]['status'] = 'completed';
        $this->log[$clientActionId]['result'] = $result;
    }

    public function failClaim(string $clientActionId, string $reason): void
    {
        $this->log[$clientActionId]['status'] = 'failed';
        $this->log[$clientActionId]['result'] = ['status' => 'error', 'reason' => $reason];
    }

    private function claim(string $clientActionId, string $type, string $parishId): void
    {
        $this->log[$clientActionId] = [
            'type' => $type,
            'parishId' => $parishId,
            'status' => 'processing',
            'result' => null,
            'claimedAt' => new \DateTimeImmutable(),
        ];
    }

    /** Test helper — lets a test simulate "claimed a while ago" without sleeping. */
    public function backdateClaim(string $clientActionId, int $secondsAgo): void
    {
        if (isset($this->log[$clientActionId])) {
            $this->log[$clientActionId]['claimedAt'] = (new \DateTimeImmutable())->modify("-{$secondsAgo} seconds");
        }
    }
}
