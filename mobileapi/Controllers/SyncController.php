<?php

namespace MinistrantManager\MobileAPI\Controllers;

use Illuminate\Http\Request;
use MinistrantManager\MobileAPI\Sync\SyncService;

/** NOT INTEGRATED (see docs/TESTING.md). `GET /api/v1/mobile/sync?cursor=...`. */
class SyncController
{
    public function __construct(private readonly SyncService $syncService)
    {
    }

    public function show(Request $request)
    {
        $parishId = $request->attributes->get('device_parish_id');
        $cursor = $request->query('cursor');

        return response()->json($this->syncService->incrementalSync($parishId, $cursor));
    }
}
