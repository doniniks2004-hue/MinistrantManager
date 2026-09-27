<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\MobileDevice;
use App\Models\Parish;
use Illuminate\Support\Carbon;

class DashboardController extends Controller
{
    public function index()
    {
        // Was flagged in review: `status='active'` on the device row is
        // NOT the same as "actually usable right now" — a device keeps
        // status=active even after its whole parish gets disabled (only
        // parish.mobile_status flips). Every "active devices" figure below
        // is therefore scoped to devices whose PARISH is also active, so
        // the dashboard can't overstate the real, currently-working fleet.
        $trulyActiveDevices = fn () => MobileDevice::where('status', 'active')
            ->whereHas('parish', fn ($q) => $q->where('mobile_status', 'active'));

        $stats = [
            'active_parishes' => Parish::where('mobile_status', 'active')->count(),
            'inactive_parishes' => Parish::where('mobile_status', 'disabled')->count(),
            'active_devices' => $trulyActiveDevices()->count(),
            'android_devices' => $trulyActiveDevices()->where('platform', 'android')->count(),
            'ios_devices' => $trulyActiveDevices()->where('platform', 'ios')->count(),
            'activations_today' => MobileDevice::whereDate('activated_at', today())->count(),
            'activations_7d' => MobileDevice::where('activated_at', '>=', Carbon::now()->subDays(7))->count(),
            'activations_30d' => MobileDevice::where('activated_at', '>=', Carbon::now()->subDays(30))->count(),
            'seen_today' => MobileDevice::whereDate('last_seen_at', today())->count(),
            'stale_30d' => $trulyActiveDevices()
                ->where(function ($q) {
                    $q->where('last_seen_at', '<', Carbon::now()->subDays(30))
                        ->orWhereNull('last_seen_at');
                })->count(),
        ];

        $versionBreakdown = $trulyActiveDevices()
            ->selectRaw('app_version, count(*) as total')
            ->groupBy('app_version')
            ->orderByDesc('total')
            ->get();

        return view('admin.dashboard', compact('stats', 'versionBreakdown'));
    }
}
