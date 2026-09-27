<?php

namespace MinistrantManager\MobileAPI\Controllers;

use Illuminate\Http\Request;
use MinistrantManager\MobileAPI\Contracts\AnnouncementsRepositoryInterface;
use MinistrantManager\MobileAPI\Contracts\AttendanceRepositoryInterface;
use MinistrantManager\MobileAPI\Contracts\EventsRepositoryInterface;
use MinistrantManager\MobileAPI\Contracts\ParishSettingsRepositoryInterface;
use MinistrantManager\MobileAPI\Contracts\PointsRepositoryInterface;
use MinistrantManager\MobileAPI\Contracts\RankingRepositoryInterface;
use MinistrantManager\MobileAPI\Contracts\ScheduleRepositoryInterface;
use MinistrantManager\MobileAPI\Contracts\SubstitutionsRepositoryInterface;
use MinistrantManager\MobileAPI\DTO\DeviceContext;
use MinistrantManager\MobileAPI\Sync\SyncService;

/**
 * NOT INTEGRATED (see docs/TESTING.md). `GET /api/v1/mobile/bootstrap`.
 * Every *RepositoryInterface is constructor-injected — Laravel's
 * container resolves them to whatever is bound in Iteration 2 (the real
 * MM adapters). In Iteration 1 there is NOTHING bound in production
 * config for these interfaces on purpose (spec decision #5: no fake
 * repositories in production) — this controller simply cannot run
 * end-to-end until that binding exists.
 */
class BootstrapController
{
    public function __construct(
        private readonly EventsRepositoryInterface $events,
        private readonly ScheduleRepositoryInterface $schedule,
        private readonly AttendanceRepositoryInterface $attendance,
        private readonly PointsRepositoryInterface $points,
        private readonly RankingRepositoryInterface $ranking,
        private readonly AnnouncementsRepositoryInterface $announcements,
        private readonly SubstitutionsRepositoryInterface $substitutions,
        private readonly ParishSettingsRepositoryInterface $settings,
        private readonly SyncService $syncService,
    ) {
    }

    public function show(Request $request)
    {
        $ctx = new DeviceContext(
            installationId: $request->attributes->get('installation_id'),
            parishId: $request->attributes->get('device_parish_id'),
            parishSlug: $request->attributes->get('parish_slug'),
            platform: $request->header('X-Platform', 'unknown'),
        );

        // Iteration 1.1 point 1 fix: this MUST be a real, non-null cursor.
        // Without it, the client's SyncMetadata.cursor stays null forever
        // and every subsequent "sync" silently re-runs a full bootstrap
        // instead of an incremental /mobile/sync — the bug report's exact
        // words: "incremental sync w praktyce nigdy się nie zaczyna".
        $cursor = $this->syncService->bootstrapCursor($ctx->parishId);

        return response()->json([
            'server_time' => now()->toIso8601String(),
            'cursor' => $cursor,
            'parish' => $this->settings->bootstrap($ctx),
            'events' => $this->events->bootstrap($ctx),
            'schedule' => $this->schedule->bootstrap($ctx),
            'attendance' => $this->attendance->bootstrap($ctx),
            'points' => $this->points->bootstrap($ctx),
            'ranking' => $this->ranking->bootstrap($ctx), // pre-computed by MM — spec decision #6
            'announcements' => $this->announcements->bootstrap($ctx),
            'substitutions' => $this->substitutions->bootstrap($ctx),
        ]);
    }
}
