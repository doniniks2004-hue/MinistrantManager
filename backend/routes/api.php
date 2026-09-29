<?php

use App\Http\Controllers\Api\ActivationController;
use App\Http\Controllers\Api\ClientConfigController;
use App\Http\Controllers\Api\DeviceController;
use App\Http\Controllers\Internal\InternalDeviceValidationController;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| app.ministrant.eu — Public device/activation API
|--------------------------------------------------------------------------
| Consumed exclusively by the Flutter app. Rate limited (see
| ActivationController) on top of Laravel's default api throttle.
| This never returns parish business data (schedules etc.) — only
| enough for the client to know which parish subdomain to talk to.
*/

Route::prefix('activation')->group(function () {
    Route::post('/check', [ActivationController::class, 'check']);
    Route::post('/confirm', [ActivationController::class, 'confirm']);
});

// Spec decision #6: global fleet config, unauthenticated, checkable
// before activation even happens (e.g. to show a forced-update screen).
Route::get('/client-config', [ClientConfigController::class, 'show']);

Route::prefix('device')->group(function () {
    Route::post('/heartbeat', [DeviceController::class, 'heartbeat']);
    Route::post('/status', [DeviceController::class, 'status']);
    Route::post('/sync-ack', [DeviceController::class, 'syncAck']);
});

/*
|--------------------------------------------------------------------------
| Device-control-plane milestone — internal, server-to-server ONLY
|--------------------------------------------------------------------------
| Called by a parish's own MobileAPI server (never the Flutter app
| directly), authenticated via that parish's own
| mobile_internal_api_secret (see InternalDeviceValidationController's
| own docblock) — NOT device_token, NOT mobile_user_token. Deliberately
| its own route group/prefix so it's trivial to point a stricter
| server-level rule (e.g. an IP allowlist, if ever wanted) at exactly
| this path without touching the public device/activation routes above.
*/
Route::prefix('internal/mobile')->group(function () {
    Route::post('/device/validate', [InternalDeviceValidationController::class, 'check']);
});
