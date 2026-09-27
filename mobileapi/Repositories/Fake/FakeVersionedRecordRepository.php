<?php

namespace MinistrantManager\MobileAPI\Repositories\Fake;

use MinistrantManager\MobileAPI\Actions\VersionConflictException;
use MinistrantManager\MobileAPI\Contracts\VersionedRecordRepositoryInterface;

/**
 * TEST IMPLEMENTATION ONLY (see FakeActionLogRepository docblock — same
 * caveat applies). Simulates a table of versioned business records
 * (schedule assignments, events, ...) with atomic check-and-write
 * semantics, matching what a real `UPDATE ... WHERE version = ?` must
 * guarantee in production.
 */
class FakeVersionedRecordRepository implements VersionedRecordRepositoryInterface
{
    private array $records = [];

    public function seed(string $id, array $data, int $version): void
    {
        $this->records[$id] = array_merge($data, ['id' => $id, 'version' => $version]);
    }

    public function find(string $id): ?array
    {
        return $this->records[$id] ?? null;
    }

    public function applyVersionedUpdate(string $id, int $expectedVersion, array $changes): array
    {
        $current = $this->records[$id] ?? null;
        if ($current === null || (int) $current['version'] !== $expectedVersion) {
            throw new VersionConflictException($current ?? [], (int) ($current['version'] ?? 0));
        }

        $updated = array_merge($current, $changes, ['version' => $expectedVersion + 1]);
        $this->records[$id] = $updated;
        return $updated;
    }
}
