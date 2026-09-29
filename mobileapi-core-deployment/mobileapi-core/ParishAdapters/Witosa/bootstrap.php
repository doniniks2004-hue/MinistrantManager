<?php
/**
 * GET /api/v1/mobile/bootstrap
 * headers: Authorization: Bearer <mobile_user_token>, X-Installation-Id: ...
 *
 * Snapshot-first (review round correction — NOT incremental/cursor-based):
 * returns the FULL current state for a fixed date window, every time.
 * The client is expected to atomically replace its local rows for this
 * exact window (one transaction: DELETE WHERE window + INSERT snapshot)
 * rather than upsert-only — see EventsRepositoryInterface's docblock for
 * why that matters given the real legacy tables have no updated_at or
 * tombstone column.
 *
 * This vertical slice wires ONLY events + schedule (Iteration 2, Krok 3D/
 * 3E) — attendance/points/ranking/announcements/substitutions come once
 * their own Legacy adapters exist; until then `/mobile/config` reports
 * those capabilities as false and the app is expected to simply not show
 * those sections, not treat their absence as an error.
 */

require __DIR__ . '/wiring.php';

use MinistrantManager\MobileAPI\Repositories\Legacy\LegacyMysqlEventsRepository;
use MinistrantManager\MobileAPI\Repositories\Legacy\LegacyMysqlScheduleRepository;
use MinistrantManager\MobileAPI\Repositories\Legacy\LegacyMysqlAnnouncementsRepository;
use MinistrantManager\MobileAPI\Http\JsonResponse;

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') {
    JsonResponse::error('method_not_allowed', 'Wymagane GET.', 405);
}

$ctx = mobileapi_device_context();
$user = mobileapi_require_user_auth($conn, $ctx);

// Review round (snapshot-first model): "np. ostatnie 7 dni + najbliższe
// 60–90 dni" for the schedule/events window. 90, not 60, chosen here —
// nothing in the spec depends on the exact number, and a longer forward
// window means fewer "why can't I see next month's schedule yet"
// support questions for a small extra payload size. Easy to tune later;
// not worth a config flag for this vertical slice.
$now = new DateTimeImmutable('now', new DateTimeZone('Europe/Warsaw'));
$windowFrom = $now->modify('-7 days')->setTime(0, 0, 0);
$windowTo = $now->modify('+90 days')->setTime(23, 59, 59);

$eventsRepo = new LegacyMysqlEventsRepository($conn);
$scheduleRepo = new LegacyMysqlScheduleRepository($conn);

$events = $eventsRepo->bootstrapWindow($ctx, $windowFrom, $windowTo);

// Review round, point 8: this vertical slice is deliberately scoped to
// "Mój grafik" (MY schedule), not the full parish board — filtering here,
// server-side, means we never send another server's user_id/assignment
// data to a client that isn't going to show it, and the client needs no
// "who is this person" catalog at all for this milestone. Repository
// itself stays general-purpose (returns EVERYONE's assignments) — this
// filter is a scope decision for THIS endpoint/milestone, not a
// limitation of LegacyMysqlScheduleRepository's contract, so widening to
// "full parish schedule + people catalog" later doesn't require touching
// the repository.
$allSchedule = $scheduleRepo->bootstrapWindow($ctx, $windowFrom, $windowTo);
$schedule = array_values(array_filter($allSchedule, fn($row) => $row['user_id'] === $user->userId));

// Hybrid dashboard milestone, P1: announcements are parish-wide (not
// per-user, unlike schedule) — no filtering needed, just the last 50.
$announcementsRepo = new LegacyMysqlAnnouncementsRepository($conn);
$announcements = $announcementsRepo->recent(50);

JsonResponse::success([
    // Review round: "generated_at" + optional "snapshot_version" instead
    // of a real change-log/cursor — this IS that metadata.
    'generated_at' => $now->format(DATE_ATOM),
    'window' => [
        'from' => $windowFrom->format(DATE_ATOM),
        'to' => $windowTo->format(DATE_ATOM),
    ],
    'user' => [
        'id' => $user->userId,
        'role_id' => $user->roleId,
        'role_name' => $user->roleName,
    ],
    'events' => $events,
    'schedule' => $schedule,
    'announcements' => $announcements,
]);
