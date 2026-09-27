<?php

use App\Http\Controllers\Api\ActivationController;
use App\Http\Controllers\Api\ClientConfigController;
use App\Http\Controllers\Api\DeviceController;
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
