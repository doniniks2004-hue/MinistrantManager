<?php

namespace MinistrantManager\MobileAPI\Controllers;

use Illuminate\Http\Request;

/**
 * NOT INTEGRATED (see docs/TESTING.md). `GET /api/v1/mobile/config` —
 * spec §15/§16/§19: dashboard layout + module list for THIS parish,
 * server-driven per decision #13. Deliberately has no repository
 * dependency of its own in Iteration 1 — a real implementation reads a
 * parish's stored dashboard/module config (wherever the admin-facing CMS
 * for it ends up living) and runs it through
 * Config\ServerDrivenUiSchema::validateDashboardConfig() before ever
 * returning it, so a malformed config is caught server-side rather than
 * shipped to devices.
 */
class ConfigController
{
    public function show(Request $request)
    {
        // Placeholder response shape ONLY — wire to the real per-parish
        // config store in Iteration 2. Structure matches spec §15/§16
        // exactly so the Flutter client's config parser can be built and
        // tested against this shape today.
        return response()->json([
            'schema_version' => 1,
            'dashboard' => ['layout' => 'grid', 'columns' => 2, 'items' => []],
            'modules' => [],
        ]);
    }
}
