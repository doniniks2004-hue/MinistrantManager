<?php

namespace MinistrantManager\MobileAPI\Repositories\Legacy;

use DateTimeImmutable;
use mysqli;
use MinistrantManager\MobileAPI\Contracts\EventsRepositoryInterface;
use MinistrantManager\MobileAPI\DTO\DeviceContext;

/**
 * Reference implementation of EventsRepositoryInterface against the real
 * legacy Ministrant Manager schema, as found in the Witosa parish
 * (Iteration 2, "Witosa jako implementacja referencyjna" — this class
 * name/shape is generic on purpose, not `WitosaEventsRepository`, so any
 * parish whose `events`/`weekday_events`/`event_modules` tables match this
 * shape can reuse it unchanged).
 *
 * Deliberately plain mysqli — this runs inside the parish's own existing
 * plain-PHP codebase, no framework (Iteration 2 point 2).
 */
final class LegacyMysqlEventsRepository implements EventsRepositoryInterface
{
    public function __construct(private readonly mysqli $conn)
    {
    }

    public function bootstrapWindow(DeviceContext $ctx, DateTimeImmutable $from, DateTimeImmutable $to): array
    {
        $fromStr = $from->format('Y-m-d H:i:s');
        $toStr = $to->format('Y-m-d H:i:s');

        $rows = [];

        // Sunday/holiday Masses.
        $stmt = $this->conn->prepare(
            'SELECT id, event_date, description, module_id
             FROM events
             WHERE event_date BETWEEN ? AND ?
             ORDER BY event_date ASC'
        );
        $stmt->bind_param('ss', $fromStr, $toStr);
        $stmt->execute();
        $id = null;
        $eventDate = null;
        $description = null;
        $moduleId = null;
        $stmt->bind_result($id, $eventDate, $description, $moduleId);
        while ($stmt->fetch()) {
            $row = [
                'id' => $id,
                'event_date' => $eventDate,
                'description' => $description,
                'module_id' => $moduleId,
            ];
            $rows[] = [
                // Review round fix, point 4: `id` is now a canonical
                // string key ("{source}:{raw_id}") — events.id and
                // weekday_events.id are TWO INDEPENDENT sequences that can
                // (and do) collide, so a client keying purely on the bare
                // integer would silently conflate two unrelated rows.
                // raw_id kept for anything that genuinely needs the int.
                'id' => 'events:' . $row['id'],
                'raw_id' => (int) $row['id'],
                'source' => 'events',
                'event_date' => $this->toIso8601($row['event_date']),
                'description' => $row['description'],
                'module_id' => $row['module_id'] !== null ? (int) $row['module_id'] : null,
                // `events` has no cancellation flag at all — a cancelled
                // Sunday Mass is handled elsewhere in the legacy app
                // (see `cancelled_meetings`, out of scope for this slice).
                'is_cancelled' => false,
            ];
        }
        $stmt->close();

        // Weekday Masses — separate table, separate id sequence, its own
        // is_cancelled flag.
        $stmt = $this->conn->prepare(
            'SELECT we.id, we.event_date, we.is_cancelled, mt.description
             FROM weekday_events we
             LEFT JOIN mass_times mt ON mt.id = we.mass_time_id
             WHERE we.event_date BETWEEN ? AND ?
             ORDER BY we.event_date ASC'
        );
        $stmt->bind_param('ss', $fromStr, $toStr);
        $stmt->execute();
        $result = $stmt->get_result();
        while ($row = $result->fetch_assoc()) {
            $rows[] = [
                'id' => 'weekday_events:' . $row['id'],
                'raw_id' => (int) $row['id'],
                'source' => 'weekday_events',
                'event_date' => $this->toIso8601($row['event_date']),
                'description' => $row['description'],
                'module_id' => null, // weekday_events has no module_id — points come from a different rule, out of scope for this read-only slice
                'is_cancelled' => (bool) $row['is_cancelled'],
            ];
        }
        $stmt->close();

        return $rows;
    }

    private function toIso8601(string $mysqlDatetime): string
    {
        // Legacy columns are plain DATETIME with no timezone — the whole
        // legacy app implicitly assumes the server's local timezone
        // (Europe/Warsaw in practice). Converting explicitly here, rather
        // than trusting DateTimeImmutable's default zone, so this doesn't
        // silently break if this code ever runs on a server configured
        // with a different default zone.
        $dt = DateTimeImmutable::createFromFormat('Y-m-d H:i:s', $mysqlDatetime, new \DateTimeZone('Europe/Warsaw'));
        return $dt->format(DATE_ATOM);
    }
}
