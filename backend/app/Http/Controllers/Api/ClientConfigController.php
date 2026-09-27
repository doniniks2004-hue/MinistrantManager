<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Models\AppConfig;

/**
 * Spec decision #6: GLOBAL fleet/app-binary configuration only — store
 * URLs, minimum/latest versions per platform, maintenance mode. This is
 * NOT parish business config (dashboard layout, modules) — that lives on
 * the parish's own subdomain at /api/v1/mobile/config (see MobileAPI
 * package). A device calls this BEFORE activation is even possible (e.g.
 * to decide whether to show a forced-update screen), so it requires no
 * auth at all.
 */
class ClientConfigController extends Controller
{
    public function show()
    {
        return response()->json([
            'minimum_supported_android_version' => AppConfig::get('minimum_supported_android_version'),
            'minimum_supported_ios_version' => AppConfig::get('minimum_supported_ios_version'),
            'latest_android_version' => AppConfig::get('latest_android_version'),
            'latest_ios_version' => AppConfig::get('latest_ios_version'),
            // Empty string, not null, when not yet published — client
            // treats "" same as absent (spec decision #15: hide the
            // button / show "coming soon" rather than a dead link).
            'android_store_url' => AppConfig::get('android_store_url', ''),
            'ios_store_url' => AppConfig::get('ios_store_url', ''),
            'maintenance_mode' => (bool) AppConfig::get('maintenance_mode', '0'),
            'maintenance_message' => AppConfig::get('maintenance_message', ''),
            'default_offline_lease_hours' => (int) AppConfig::get('offline_lease_hours', 72),
        ]);
    }
}
