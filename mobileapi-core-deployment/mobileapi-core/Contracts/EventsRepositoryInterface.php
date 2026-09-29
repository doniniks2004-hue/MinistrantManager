<?php

namespace MinistrantManager\MobileAPI\Contracts;

use DateTimeImmutable;
use MinistrantManager\MobileAPI\DTO\DeviceContext;

interface EventsRepositoryInterface
{
    /**
     * Iteration 2: fleshed out from Iteration 1's placeholder
     * `bootstrap(DeviceContext): array`, and aligned with the snapshot-first
     * sync model (review round): this returns the FULL current snapshot for
     * [$from, $to] every time — never a partial "changes since X" delta.
     * The client is expected to atomically replace its local rows for this
     * exact window (DELETE WHERE window + INSERT snapshot, one transaction)
     * rather than upsert-only, which is what correctly handles rows deleted
     * server-side even though the real legacy tables have no updated_at or
     * tombstone column (see the schema map's finding).
     *
     * A real parish has events living in TWO source tables (Sunday/holiday
     * Masses in `events`, weekday Masses in `weekday_events`), each with
     * their OWN independent id sequence — id=17 can exist in both at once,
     * meaning the same integer means two different rows. Review round fix:
     * `id` is therefore a CANONICAL STRING key ("{source}:{raw_id}", e.g.
     * "events:17" / "weekday_events:17") — the field a client keys its
     * local storage on. `raw_id` is still included for anything that
     * genuinely needs the bare integer.
     *
     * @return array<int, array{
     *   id: string,               // canonical "{source}:{raw_id}" — use THIS as the client-side primary key, never raw_id alone
     *   raw_id: int,              // only unique WITHIN source — never use alone as a cross-source key
     *   source: string,           // 'events' | 'weekday_events'
     *   event_date: string,       // ISO 8601
     *   description: ?string,
     *   module_id: ?int,
     *   is_cancelled: bool,
     * }>
     */
    public function bootstrapWindow(DeviceContext $ctx, DateTimeImmutable $from, DateTimeImmutable $to): array;
}
