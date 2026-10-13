<?php

namespace MinistrantManager\MobileAPI\Repositories\Legacy;

use DateTimeImmutable;
use mysqli;
use MinistrantManager\MobileAPI\Contracts\ScheduleRepositoryInterface;
use MinistrantManager\MobileAPI\DTO\DeviceContext;

/**
 * Reference implementation of ScheduleRepositoryInterface — see
 * LegacyMysqlEventsRepository's docblock for the general "why plain
 * mysqli, why not Witosa-specific naming" rationale; the same applies
 * here.
 */
final class LegacyMysqlScheduleRepository implements ScheduleRepositoryInterface
{
    public function __construct(private readonly mysqli $conn)
    {
    }

    public function bootstrapWindow(DeviceContext $ctx, DateTimeImmutable $from, DateTimeImmutable $to): array
    {
        $fromStr = $from->format('Y-m-d H:i:s');
        $toStr = $to->format('Y-m-d H:i:s');

        $rows = [];

        // Sunday/holiday assignments: `schedule` rows joined to `events`
        // purely to filter by the event's date (schedule itself carries no
        // date of its own).
        $stmt = $this->conn->prepare(
            'SELECT s.id, s.event_id, s.user_id, s.guest_name, s.is_present, s.status
             FROM schedule s
             JOIN events e ON e.id = s.event_id
             WHERE e.event_date BETWEEN ? AND ?'
        );
        $stmt->bind_param('ss', $fromStr, $toStr);
        $stmt->execute();
        $id = null;
        $eventId = null;
        $userId = null;
        $guestName = null;
        $isPresent = null;
        $status = null;
        $stmt->bind_result($id, $eventId, $userId, $guestName, $isPresent, $status);
        while ($stmt->fetch()) {
            $row = [
                'id' => $id,
                'event_id' => $eventId,
                'user_id' => $userId,
                'guest_name' => $guestName,
                'is_present' => $isPresent,
                'status' => $status,
            ];
            $rows[] = [
                // Review round fix, point 4: canonical string keys, both
                // for this row's own id AND for the event it references —
                // `schedule.id` and `events.id`/`weekday_events.id` are all
                // independent integer sequences that can collide.
                'id' => 'schedule:' . $row['id'],
                'raw_id' => (int) $row['id'],
                'event_id' => 'events:' . $row['event_id'],
                'event_source' => 'events',
                'user_id' => $row['user_id'] !== null ? (int) $row['user_id'] : null,
                'guest_name' => $row['guest_name'],
                'is_present' => (bool) $row['is_present'],
                'status' => $row['status'],
            ];
        }
        $stmt->close();

        // Weekday assignments: `weekday_events` carries user_id and
        // event_date directly — there is no separate join table, and no
        // `is_present`/`status` concept at all on this table (see the
        // interface docblock). A weekday event with a NULL user_id is an
        // unfilled slot, not represented as a row here — the client
        // simply won't see an assignment for that event id.
        $stmt = $this->conn->prepare(
            'SELECT id, user_id
             FROM weekday_events
             WHERE event_date BETWEEN ? AND ? AND user_id IS NOT NULL'
        );
        $stmt->bind_param('ss', $fromStr, $toStr);
        $stmt->execute();
        $id = null;
        $userId = null;
        $stmt->bind_result($id, $userId);
        while ($stmt->fetch()) {
            $row = [
                'id' => $id,
                'user_id' => $userId,
            ];
            $rows[] = [
                // This assignment IS the weekday_events row — its own
                // canonical id and its event_id are the same value,
                // self-referential, since there is no separate "schedule
                // row" for these (see the interface docblock).
                'id' => 'weekday_events:' . $row['id'],
                'raw_id' => (int) $row['id'],
                'event_id' => 'weekday_events:' . $row['id'],
                'event_source' => 'weekday_events',
                'user_id' => (int) $row['user_id'],
                'guest_name' => null,
                'is_present' => false, // weekday_events has no presence tracking in this legacy schema at all
                'status' => 'assigned',
            ];
        }
        $stmt->close();

        return $rows;
    }
}
