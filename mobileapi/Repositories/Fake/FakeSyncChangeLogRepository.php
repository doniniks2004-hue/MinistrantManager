<?php

namespace MinistrantManager\MobileAPI\Repositories\Fake;

use MinistrantManager\MobileAPI\Contracts\SyncChangeLogRepositoryInterface;
use MinistrantManager\MobileAPI\DTO\SyncChange;

/**
 * TEST IMPLEMENTATION ONLY. Cursor here is simply "index into the array,
 * as a string" — a real adapter uses an auto-increment id or timestamp,
 * but the CONTRACT (opaque cursor in, {changes, nextCursor, hasMore} out)
 * is identical, which is the whole point of testing against this fake.
 */
class FakeSyncChangeLogRepository implements SyncChangeLogRepositoryInterface
{
    /** @var array<string, SyncChange[]> keyed by parishId */
    private array $log = [];

    public function append(string $parishId, SyncChange $change): void
    {
        $this->log[$parishId][] = $change;
    }

    public function changesSince(string $parishId, ?string $cursor, int $limit = 500): array
    {
        $all = $this->log[$parishId] ?? [];
        $startIndex = $cursor === null ? 0 : (int) $cursor;

        $slice = array_slice($all, $startIndex, $limit);
        $endIndex = $startIndex + count($slice);

        return [
            'changes' => $slice,
            'nextCursor' => (string) $endIndex,
            // THE fix: whether more rows exist beyond nextCursor, checked
            // directly against the real log length — not derived from
            // count($slice), which conflates "empty page" (correctly
            // hasMore=false) with "last page happened to be non-empty but
            // was still the last one" (also hasMore=false, but the old
            // `count($changes) > 0` heuristic wrongly said true).
            'hasMore' => $endIndex < count($all),
        ];
    }

    public function currentCursor(string $parishId): string
    {
        return (string) count($this->log[$parishId] ?? []);
    }
}
