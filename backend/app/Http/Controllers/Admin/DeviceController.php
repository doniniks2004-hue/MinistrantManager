<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\MobileDevice;
use App\Services\AuditLogger;
use Illuminate\Http\Request;

class DeviceController extends Controller
{
    public function index(Request $request)
    {
        $query = MobileDevice::with('parish')->orderByDesc('last_seen_at');

        if ($search = $request->get('q')) {
            $query->where(function ($q) use ($search) {
                $q->where('device_model', 'like', "%$search%")
                    ->orWhere('device_label', 'like', "%$search%")
                    ->orWhereHas('parish', fn ($p) => $p->where('name', 'like', "%$search%")
                        ->orWhere('subdomain', 'like', "%$search%"));
            });
        }

        if ($status = $request->get('status')) {
            $query->where('status', $status);
        }
        if ($platform = $request->get('platform')) {
            $query->where('platform', $platform);
        }
        if ($seen = $request->get('seen')) {
            $query->where('last_seen_at', '>=', match ($seen) {
                'today' => today(),
                '7d' => now()->subDays(7),
                '30d' => now()->subDays(30),
                default => now()->subYears(50),
            });
            if ($seen === 'stale') {
                $query->where('last_seen_at', '<', now()->subDays(30));
            }
        }

        $devices = $query->paginate(50)->withQueryString();

        return view('admin.devices.index', compact('devices'));
    }

    public function revoke(MobileDevice $device)
    {
        $device->update([
            'status' => 'revoked',
            'revoked_at' => now(),
            'revoked_by' => auth('admin')->id(),
        ]);

        AuditLogger::log('device.revoked', 'MobileDevice', $device->id, [
            'device_model' => $device->device_model,
            'parish' => $device->parish->slug,
        ]);

        return back()->with('status', 'Urządzenie zostało dezaktywowane.');
    }

    public function rename(Request $request, MobileDevice $device)
    {
        $data = $request->validate(['device_label' => ['nullable', 'string', 'max:255']]);
        $device->update(['device_label' => $data['device_label']]);

        return back()->with('status', 'Zaktualizowano nazwę urządzenia.');
    }
}
