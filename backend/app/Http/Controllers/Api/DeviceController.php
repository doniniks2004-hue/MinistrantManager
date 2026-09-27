<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Models\MobileDevice;
use App\Services\TokenService;
use Illuminate\Http\Request;

/**
 * Endpoints called by an already-activated device: heartbeat and status
 * check. Authenticated via the device_token issued at activation (sent as
 * "Authorization: Bearer <device_token>"), never via installation_id alone.
 */
class DeviceController extends Controller
{
    /**
     * Called on: app start, foreground resume, successful sync.
     * Updates last_seen_at / app_version / os_version and returns the
     * authoritative status the client must obey (ACTIVE / REVOKED / PARISH_DISABLED).
     */
    public function heartbeat(Request $request)
    {
        $device = $this->authenticateDevice($request);

        $data = $request->validate([
            'app_version' => ['nullable', 'string', 'max:50'],
            'os_version' => ['nullable', 'string', 'max:100'],
        ]);

        $device->update([
            'last_seen_at' => now(),
            'app_version' => $data['app_version'] ?? $device->app_version,
            'os_version' => $data['os_version'] ?? $device->os_version,
        ]);

        return $this->statusResponse($device);
    }

    /**
     * Lightweight status check, meant to be called before every sync so the
     * client can honor DEVICE_REVOKED / PARISH_DISABLED promptly whenever it
     * *does* have connectivity. Also refreshes last_authorization_check,
     * which is what the offline-lease countdown on the client is based on.
     */
    public function status(Request $request)
    {
        $device = $this->authenticateDevice($request);

        // Review round fix: app_version/os_version were accepted by
        // heartbeat() but NOT here — the client now sends them on every
        // /device/status call too, and they're applied BEFORE
        // DeviceStatusEvaluator runs, so UPDATE_REQUIRED is judged
        // against the version the device says it's running right now,
        // not whatever was last recorded at activation/heartbeat time
        // (which could be stale for a device that just updated but
        // hasn't heartbeat'd yet).
        $data = $request->validate([
            'app_version' => ['nullable', 'string', 'max:50'],
            'os_version' => ['nullable', 'string', 'max:100'],
        ]);

        $device->update([
            'last_authorization_check' => now(),
            'app_version' => $data['app_version'] ?? $device->app_version,
            'os_version' => $data['os_version'] ?? $device->os_version,
        ]);

        return $this->statusResponse($device);
    }

    /**
     * Was flagged in review as dead: `last_sync_at` existed as a column but
     * nothing ever wrote to it, because the central backend never sees the
     * actual bootstrap/sync traffic — that happens entirely against the
     * parish subdomain. The client now calls this right after a successful
     * SyncEngine.runFullSync() (see mobile app's _acknowledgeSyncToCentral),
     * making the panel's "last sync" column reflect reality instead of
     * always being empty.
     */
    public function syncAck(Request $request)
    {
        $device = $this->authenticateDevice($request);
        $device->update(['last_sync_at' => now()]);

        return response()->json(['ok' => true]);
    }

    private function authenticateDevice(Request $request): MobileDevice
    {
        $raw = $request->bearerToken();
        abort_if(!$raw, 401, 'Missing device token.');

        $device = MobileDevice::where('device_token_hash', TokenService::hash($raw))
            ->with('parish')
            ->first();

        abort_if(!$device, 401, 'Unknown device token.');

        return $device;
    }

    private function statusResponse(MobileDevice $device)
    {
        // Iteration 1.1 point 3 fix: delegates to the framework-free,
        // unit-tested DeviceStatusEvaluator rather than duplicating the
        // decision inline — the original bug (comparing against
        // `minimum_supported_app_version`, a key SettingsController never
        // actually wrote, since it writes the platform-specific keys
        // below) is exactly the kind of mistake that's now caught by
        // /standalone-tests/test_device_status_evaluator.php.
        $evaluated = \App\Services\DeviceStatusEvaluator::evaluate(
            platform: $device->platform,
            appVersion: $device->app_version,
            deviceRevoked: $device->status === 'revoked',
            parishActive: $device->parish->isActive(),
            minVersionAndroid: \App\Models\AppConfig::get('minimum_supported_android_version'),
            minVersionIos: \App\Models\AppConfig::get('minimum_supported_ios_version'),
        );

        return response()->json([
            'status' => $evaluated['state'],
            'server_url' => $device->parish->server_url,
            'minimum_supported_app_version' => $evaluated['minimum_supported_app_version'],
            // Iteration 1.1 point 4 fix: was reading the GLOBAL default
            // directly, ignoring Parish::effectiveOfflineLeaseHours()'s
            // per-parish override (which already existed and worked
            // correctly — it just wasn't being called from here).
            'offline_lease_hours' => $device->parish->effectiveOfflineLeaseHours(),
            'checked_at' => now()->toIso8601String(),
        ]);
    }
}
