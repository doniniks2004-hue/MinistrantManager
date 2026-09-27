<?php

namespace MinistrantManager\MobileAPI\Sync;

use MinistrantManager\MobileAPI\Contracts\SyncChangeLogRepositoryInterface;

/**
 * Backs `GET /api/v1/mobile/bootstrap`'s cursor field AND
 * `GET /api/v1/mobile/sync?cursor=...` (spec §10). Deliberately thin —
 * all the actual "what changed" bookkeeping lives in whatever writes to
 * SyncChangeLogRepositoryInterface (spec decision #7). This class just
 * shapes that log into the response envelope the Flutter SyncEngine
 * expects, split by create/update vs delete so the client can apply
 * tombstones without inspecting `operation` itself for every entity type.
 */
class SyncService
{
    public function __construct(private readonly SyncChangeLogRepositoryInterface $changeLog)
    {
    }

    /**
     * Iteration 1.1 point 1: the cursor a bootstrap snapshot must record,
     * so the client's first `/mobile/sync?cursor=...` afterwards returns
     * only changes strictly newer than what bootstrap already included.
     * BootstrapController MUST call this and put the result in its JSON
     * response's top-level "cursor" field — the bug being fixed here is
     * exactly that it wasn't, so the client stored `cursor: null` forever
     * and every "sync" silently re-ran a full bootstrap instead.
     */
    public function bootstrapCursor(string $parishId): string
    {
        return $this->changeLog->currentCursor($parishId);
    }

    public function incrementalSync(string $parishId, ?string $cursor): array
    {
        ['changes' => $changes, 'nextCursor' => $nextCursor, 'hasMore' => $hasMore] =
            $this->changeLog->changesSince($parishId, $cursor);

        $upserts = [];
        $deletes = [];

        foreach ($changes as $change) {
            if ($change->operation === 'delete') {
                $deletes[$change->entityType][] = $change->entityId;
            } else {
                $upserts[$change->entityType][] = $change->data;
            }
        }

        return [
            'cursor' => $nextCursor,
            'changes' => $upserts,   // e.g. ['events' => [...], 'announcements' => [...]]
            'deleted' => $deletes,   // e.g. ['events' => ['123', '456']] — spec §10 tombstones
            // Iteration 1.1 point 2 fix: this now comes straight from the
            // repository's real "does another row exist past nextCursor"
            // check, not from count($changes) > 0.
            'has_more' => $hasMore,
        ];
    }
}
