<?php

use App\Http\Controllers\Admin\AdminManagementController;
use App\Http\Controllers\Admin\AuditLogController;
use App\Http\Controllers\Admin\AuthController;
use App\Http\Controllers\Admin\DashboardController;
use App\Http\Controllers\Admin\DeviceController;
use App\Http\Controllers\Admin\ParishController;
use App\Http\Controllers\Admin\SettingsController;
use App\Http\Controllers\Public\ActivationLandingController;
use Illuminate\Support\Facades\Route;

// Public (no auth) on purpose: this is what a QR scanned with a normal
// camera app opens in a browser. See ActivationLandingController docblock.
Route::get('/activate/{token}', [ActivationLandingController::class, 'show'])->name('activate.landing');

/*
|--------------------------------------------------------------------------
| app.ministrant.eu — Admin panel
|--------------------------------------------------------------------------
| This is the ONLY panel served by this app. It never serves parish data
| (schedules, attendance, points) — that lives on each parish's own
| subdomain (chwk.ministrant.eu/api/v1/...), running the MobileAPI package
| installed into the existing Ministrant Manager backend.
*/

Route::prefix('admin')->name('admin.')->group(function () {
    Route::middleware('guest:admin')->group(function () {
        Route::get('/login', [AuthController::class, 'showLogin'])->name('login');
        Route::post('/login', [AuthController::class, 'login']);
        Route::get('/login/totp', [AuthController::class, 'showTotp'])->name('login.totp');
        Route::post('/login/totp', [AuthController::class, 'verifyTotp']);
        Route::post('/login/recovery-code', [AuthController::class, 'verifyRecoveryCode'])->name('login.recovery-code');

        Route::get('/totp/setup', [AuthController::class, 'showTotpSetup'])->name('totp.setup');
        Route::post('/totp/setup', [AuthController::class, 'storeTotpSetup']);
    });

    Route::middleware('auth:admin')->group(function () {
        Route::post('/logout', [AuthController::class, 'logout'])->name('logout');

        // Shown exactly once, immediately after recovery codes are
        // (re)generated — see AuthController::showRecoveryCodesOnce().
        Route::get('/recovery-codes', [AuthController::class, 'showRecoveryCodesOnce'])->name('recovery-codes.show');
        Route::post('/recovery-codes/regenerate', [AuthController::class, 'regenerateRecoveryCodes'])->name('recovery-codes.regenerate');

        Route::get('/', [DashboardController::class, 'index'])->name('dashboard');

        Route::get('/parishes', [ParishController::class, 'index'])->name('parishes.index');
        Route::get('/parishes/create', [ParishController::class, 'create'])->name('parishes.create');
        Route::post('/parishes', [ParishController::class, 'store'])->name('parishes.store');
        Route::get('/parishes/{parish}', [ParishController::class, 'show'])->name('parishes.show');
        Route::post('/parishes/{parish}/offline-lease', [ParishController::class, 'updateOfflineLease'])->name('parishes.offline-lease');
        Route::post('/parishes/{parish}/codes', [ParishController::class, 'generateCode'])->name('parishes.codes.generate');
        Route::post('/parishes/{parish}/codes/{code}/revoke', [ParishController::class, 'revokeCode'])->name('parishes.codes.revoke');
        Route::post('/parishes/{parish}/disable', [ParishController::class, 'disable'])->name('parishes.disable');
        Route::post('/parishes/{parish}/enable', [ParishController::class, 'enable'])->name('parishes.enable');

        Route::get('/devices', [DeviceController::class, 'index'])->name('devices.index');

        // Iteration 1.1 point 14: available to BOTH roles — AuditLogController
        // itself enforces admin_user_id scoping for non-SUPER_ADMIN callers,
        // rather than gating the whole route behind 'super_admin'.
        Route::get('/audit-log', [AuditLogController::class, 'index'])->name('audit-log.index');
        Route::post('/devices/{device}/revoke', [DeviceController::class, 'revoke'])->name('devices.revoke');
        Route::post('/devices/{device}/rename', [DeviceController::class, 'rename'])->name('devices.rename');

        // SUPER_ADMIN only — enforced both by the `super_admin` route
        // middleware AND by per-action checks inside the controller (some
        // actions are restricted even between two SUPER_ADMINs — see
        // AdminUser::canDeactivate()/canChangeRoleOf()/canResetMfaOf()).
        Route::middleware('super_admin')->group(function () {
            Route::get('/admins', [AdminManagementController::class, 'index'])->name('admins.index');
            Route::get('/admins/create', [AdminManagementController::class, 'create'])->name('admins.create');
            Route::post('/admins', [AdminManagementController::class, 'store'])->name('admins.store');
            Route::post('/admins/{admin}/role', [AdminManagementController::class, 'updateRole'])->name('admins.role');
            Route::post('/admins/{admin}/deactivate', [AdminManagementController::class, 'deactivate'])->name('admins.deactivate');
            Route::post('/admins/{admin}/reactivate', [AdminManagementController::class, 'reactivate'])->name('admins.reactivate');
            Route::post('/admins/{admin}/reset-mfa', [AdminManagementController::class, 'resetMfa'])->name('admins.reset-mfa');

            Route::get('/settings', [SettingsController::class, 'edit'])->name('settings.edit');
            Route::post('/settings', [SettingsController::class, 'update'])->name('settings.update');
        });
    });
});

Route::redirect('/', '/admin');
