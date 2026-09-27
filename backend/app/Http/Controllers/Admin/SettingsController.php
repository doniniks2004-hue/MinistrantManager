<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\AppConfig;
use App\Services\AuditLogger;
use Illuminate\Http\Request;

/**
 * SUPER_ADMIN-only screen for the global fleet config values exposed
 * read-only (and unauthenticated) via GET /api/client-config. Deliberately
 * a flat key/value form — see AppConfig model — rather than a bespoke
 * column per setting, so adding a new global switch later doesn't need a
 * migration.
 */
class SettingsController extends Controller
{
    private const KEYS = [
        'minimum_supported_android_version',
        'minimum_supported_ios_version',
        'latest_android_version',
        'latest_ios_version',
        'android_store_url',
        'ios_store_url',
        'maintenance_mode',
        'maintenance_message',
        'offline_lease_hours',
    ];

    public function edit()
    {
        $values = collect(self::KEYS)->mapWithKeys(fn ($key) => [$key => AppConfig::get($key, '')]);
        return view('admin.settings.edit', ['values' => $values]);
    }

    public function update(Request $request)
    {
        $data = $request->validate([
            'minimum_supported_android_version' => ['required', 'string', 'max:20'],
            'minimum_supported_ios_version' => ['required', 'string', 'max:20'],
            'latest_android_version' => ['required', 'string', 'max:20'],
            'latest_ios_version' => ['required', 'string', 'max:20'],
            'android_store_url' => ['nullable', 'url', 'max:500'],
            'ios_store_url' => ['nullable', 'url', 'max:500'],
            'maintenance_mode' => ['nullable', 'boolean'],
            'maintenance_message' => ['nullable', 'string', 'max:500'],
            'offline_lease_hours' => ['required', 'integer', 'min:1', 'max:720'],
        ]);

        $data['maintenance_mode'] = $request->boolean('maintenance_mode') ? '1' : '0';

        foreach (self::KEYS as $key) {
            AppConfig::set($key, (string) ($data[$key] ?? ''));
        }

        AuditLogger::log('settings.updated', null, null, ['keys' => self::KEYS]);

        return back()->with('status', 'Ustawienia globalne zostały zaktualizowane.');
    }
}
