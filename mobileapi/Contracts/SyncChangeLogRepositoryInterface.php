<?php

namespace MinistrantManager\MobileAPI\Contracts;

use MinistrantManager\MobileAPI\DTO\SyncChange;

/**
 * Spec decision #7: mobile sync owns its own change-log/tombstone
 * mechanism (a `mobile_sync_changes` table, conceptually), rather than
 * requiring every existing MM table to already have deleted_at. Whoever
 * mutates a business record (through whatever process — the existing MM
 * web app, an admin action, this API) is responsible for appending one
 * SyncChange row per parish per mutation; this interface only covers
 * reading that log back out for incremental sync.
 */
interface SyncChangeLogRepositoryInterface
{
    /**
     * @return array{changes: SyncChange[], nextCursor: string, hasMore: bool}
     *   hasMore MUST reflect whether at least one more row exists beyond
     *   nextCursor at query time (e.g. a real adapter does
     *   `SELECT EXISTS(SELECT 1 FROM mobile_sync_changes WHERE parish_id=? AND id > ? LIMIT 1)`)
     *   — NOT "count($changes) > 0", which was Iteration 1.1's bug: an
     *   empty page (nothing changed since $cursor) is a normal, valid,
     *   NOT-has-more result, while a full page (limit reached) usually
     *   DOES have more even though changes is non-empty. The two are not
     *   the same thing and conflating them broke incremental sync for any
     *   parish with more than one page's worth of pending changes.
     */
    public function changesSince(string $parishId, ?string $cursor, int $limit = 500): array;

    public function append(string $parishId, SyncChange $change): void;

    /**
     * The change log's current high-watermark for $parishId — i.e. "the
     * cursor a bootstrap snapshot taken right now should record", so that
     * the FIRST `changesSince($parishId, $thisCursor)` call afterwards
     * returns only changes strictly newer than the snapshot (spec:
     * "Iteration 1.1 point 1" — bootstrap must return a real cursor, not
     * null, or the client never leaves bootstrap-mode).
     */
    public function currentCursor(string $parishId): string;
}
