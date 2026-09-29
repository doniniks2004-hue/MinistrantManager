<?php

namespace MinistrantManager\MobileAPI\Contracts;

use DateTimeImmutable;
use MinistrantManager\MobileAPI\DTO\DeviceContext;

interface ScheduleRepositoryInterface
{
    /**
     * Same snapshot-first contract as EventsRepositoryInterface — see its
     * docblock for the general model, and for WHY `id`/`event_id` are
     * canonical strings ("{source}:{raw_id}"), not bare integers: both
     * `schedule.id` and the two event-id sequences it can reference
     * (`events.id` / `weekday_events.id`) are independent and can collide.
     *
     * Sunday/holiday assignments live in the `schedule` table (many rows
     * per event, referencing `events`); weekday assignments are inline
     * directly on `weekday_events` (one server per weekday event, no
     * separate table) — for those, this row's own `id` and its `event_id`
     * are the SAME canonical value (self-referential: the assignment IS
     * the event row, there is no separate "schedule row" for it).
     *
     * @return array<int, array{
     *   id: string,               // canonical "{source}:{raw_id}" for THIS row — 'schedule:51' or 'weekday_events:17'
     *   raw_id: int,
     *   event_id: string,         // canonical id of the EVENT this assignment is for — 'events:17' or 'weekday_events:17'
     *   event_source: string,     // 'events' | 'weekday_events' — matches EventsRepositoryInterface's `source`
     *   user_id: ?int,
     *   guest_name: ?string,      // filled in only for `events`-sourced rows that have no real user (a guest server)
     *   is_present: bool,
     *   status: string,           // 'assigned' | 'substitution_needed' (weekday rows are always 'assigned' — no such state exists on that table)
     * }>
     */
    public function bootstrapWindow(DeviceContext $ctx, DateTimeImmutable $from, DateTimeImmutable $to): array;
}
