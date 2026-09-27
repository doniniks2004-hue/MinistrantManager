<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Services\AuditLogger;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Validation\ValidationException;
use PragmaRX\Google2FA\Google2FA;
use App\Services\RecoveryCodeService;
use BaconQrCode\Renderer\ImageRenderer;
use BaconQrCode\Renderer\Image\SvgImageBackEnd;
use BaconQrCode\Renderer\RendererStyle\RendererStyle;
use BaconQrCode\Writer;

/**
 * Admin login with mandatory TOTP second factor (no SMS — per spec §37).
 * Flow: POST credentials -> if correct, session gets a "pending_admin_id"
 * and we ask for TOTP -> POST totp code -> full admin session.
 */
class AuthController extends Controller
{
    public function showLogin()
    {
        return view('admin.auth.login');
    }

    public function login(Request $request)
    {
        $credentials = $request->validate([
            'email' => ['required', 'email'],
            'password' => ['required', 'string'],
        ]);

        $throttleKey = 'admin-login:' . $request->ip();
        if (RateLimiter::tooManyAttempts($throttleKey, 5)) {
            AuditLogger::log('admin.login_rate_limited', null, null, ['ip' => $request->ip()]);
            throw ValidationException::withMessages(['email' => 'Zbyt wiele prób logowania. Spróbuj ponownie za kilka minut.']);
        }

        $admin = \App\Models\AdminUser::where('email', $credentials['email'])->first();

        if (!$admin || !\Illuminate\Support\Facades\Hash::check($credentials['password'], $admin->password)) {
            RateLimiter::hit($throttleKey, 300);
            AuditLogger::log('admin.login_failed', null, null, ['email' => $credentials['email']]);
            throw ValidationException::withMessages(['email' => 'Nieprawidłowy e-mail lub hasło.']);
        }

        if (!$admin->is_active) {
            AuditLogger::log('admin.login_blocked_inactive', 'AdminUser', $admin->id);
            throw ValidationException::withMessages(['email' => 'To konto administratora zostało dezaktywowane.']);
        }

        RateLimiter::clear($throttleKey);

        if ($admin->totp_enabled) {
            $request->session()->put('pending_admin_id', $admin->id);
            return redirect()->route('admin.login.totp');
        }

        // First login before MFA is configured: force setup, don't allow bypass.
        $request->session()->put('pending_admin_id', $admin->id);
        return redirect()->route('admin.totp.setup');
    }

    public function showTotp(Request $request)
    {
        abort_unless($request->session()->has('pending_admin_id'), 403);
        return view('admin.auth.totp');
    }

    public function verifyTotp(Request $request)
    {
        $adminId = $request->session()->get('pending_admin_id');
        abort_unless($adminId, 403);

        $data = $request->validate(['code' => ['required', 'string', 'size:6']]);

        $admin = \App\Models\AdminUser::findOrFail($adminId);

        // Iteration 1.1 point 8 fix: a 6-digit TOTP code has only one
        // million possible values — with ZERO rate limiting an attacker
        // who already has the password (or is testing this endpoint
        // directly) could brute-force it in a very feasible number of
        // requests. Keyed per admin+IP, same shape as the recovery-code
        // limiter right below this method.
        $throttleKey = 'admin-totp:' . $request->ip() . ':' . $admin->id;
        $this->throttleTotpOrFail($throttleKey);

        $google2fa = new Google2FA();
        $valid = $google2fa->verifyKey($admin->totp_secret, $data['code']);

        if (!$valid) {
            RateLimiter::hit($throttleKey, 300);
            AuditLogger::log('admin.totp_failed', 'AdminUser', $admin->id);
            throw ValidationException::withMessages(['code' => 'Nieprawidłowy kod TOTP.']);
        }
        RateLimiter::clear($throttleKey);

        $request->session()->forget('pending_admin_id');
        Auth::guard('admin')->login($admin);
        $request->session()->regenerate();

        $admin->update([
            'last_login_at' => now(),
            'last_login_ip' => $request->ip(),
        ]);

        AuditLogger::log('admin.login_success', 'AdminUser', $admin->id);

        return redirect()->route('admin.dashboard');
    }

    /**
     * Shared TOTP rate limiter (Iteration 1.1 point 8): used by
     * verifyTotp(), storeTotpSetup(), and regenerateRecoveryCodes() —
     * every place a bare 6-digit code is checked. 5 failed attempts /
     * 5 minutes, keyed by whatever caller-specific key is passed in
     * (always admin_id + IP), with an audit event on lockout.
     */
    private function throttleTotpOrFail(string $key): void
    {
        if (RateLimiter::tooManyAttempts($key, 5)) {
            AuditLogger::log('admin.totp_rate_limited', null, null, ['key' => $key]);
            throw ValidationException::withMessages(['code' => 'Zbyt wiele nieudanych prób. Spróbuj ponownie za kilka minut.']);
        }
    }

    /**
     * Alternate second-factor path when the admin has lost their
     * authenticator device. Consumes exactly one recovery code (spec
     * decision #12) and logs a distinct audit event so recovery-code
     * usage is visible/auditable separately from normal TOTP logins.
     */
    public function verifyRecoveryCode(Request $request, RecoveryCodeService $recoveryCodes)
    {
        $adminId = $request->session()->get('pending_admin_id');
        abort_unless($adminId, 403);

        $data = $request->validate(['recovery_code' => ['required', 'string']]);
        $admin = \App\Models\AdminUser::findOrFail($adminId);

        $throttleKey = 'admin-recovery:' . $request->ip() . ':' . $admin->id;
        if (RateLimiter::tooManyAttempts($throttleKey, 5)) {
            AuditLogger::log('admin.recovery_code_rate_limited', 'AdminUser', $admin->id);
            throw ValidationException::withMessages(['recovery_code' => 'Zbyt wiele prób. Spróbuj ponownie za kilka minut.']);
        }

        if (!$recoveryCodes->attemptConsume($admin, $data['recovery_code'])) {
            RateLimiter::hit($throttleKey, 300);
            AuditLogger::log('admin.recovery_code_failed', 'AdminUser', $admin->id);
            throw ValidationException::withMessages(['recovery_code' => 'Nieprawidłowy lub już wykorzystany kod odzyskiwania.']);
        }
        RateLimiter::clear($throttleKey);

        $request->session()->forget('pending_admin_id');
        Auth::guard('admin')->login($admin);
        $request->session()->regenerate();

        $admin->update(['last_login_at' => now(), 'last_login_ip' => $request->ip()]);
        AuditLogger::log('admin.login_via_recovery_code', 'AdminUser', $admin->id, [
            'remaining_codes' => $recoveryCodes->remainingCount($admin),
        ]);

        return redirect()->route('admin.dashboard')
            ->with('status', 'Zalogowano kodem odzyskiwania. Zostało Ci ' . $recoveryCodes->remainingCount($admin) . ' kodów — rozważ ich regenerację po ponownym skonfigurowaniu aplikacji Authenticator.');
    }

    /**
     * Was flagged in review as a dead end: login() redirects here for any
     * admin without totp_enabled, but the route/view/logic didn't exist —
     * a freshly created admin had nowhere to go on first login. This is
     * the missing piece: generate a secret once (stored but NOT yet
     * "enabled" until confirmed), render it as both a scannable QR and a
     * manual-entry string, then require one valid code before flipping
     * totp_enabled on.
     */
    public function showTotpSetup(Request $request)
    {
        $adminId = $request->session()->get('pending_admin_id');
        abort_unless($adminId, 403);

        $admin = \App\Models\AdminUser::findOrFail($adminId);
        $google2fa = new Google2FA();

        // Reuse a secret already generated earlier in this same setup
        // attempt (e.g. the admin refreshed the page) instead of
        // invalidating a code they might already be about to scan.
        if (!$admin->totp_secret) {
            $admin->update(['totp_secret' => $google2fa->generateSecretKey()]);
        }

        $otpAuthUrl = $google2fa->getQRCodeUrl(
            config('app.name', 'Ministrant Manager'),
            $admin->email,
            $admin->totp_secret
        );

        $renderer = new ImageRenderer(new RendererStyle(200), new SvgImageBackEnd());
        $qrSvg = (new Writer($renderer))->writeString($otpAuthUrl);

        return view('admin.auth.totp-setup', [
            'qrSvg' => $qrSvg,
            'secret' => $admin->totp_secret,
        ]);
    }

    public function storeTotpSetup(Request $request)
    {
        $adminId = $request->session()->get('pending_admin_id');
        abort_unless($adminId, 403);

        $data = $request->validate(['code' => ['required', 'string', 'size:6']]);

        $admin = \App\Models\AdminUser::findOrFail($adminId);

        // Iteration 1.1 point 8 fix: first-setup confirmation is just as
        // brute-forceable as normal login TOTP if left unlimited.
        $throttleKey = 'admin-totp-setup:' . $request->ip() . ':' . $admin->id;
        $this->throttleTotpOrFail($throttleKey);

        $google2fa = new Google2FA();

        if (!$google2fa->verifyKey($admin->totp_secret, $data['code'])) {
            RateLimiter::hit($throttleKey, 300);
            AuditLogger::log('admin.totp_setup_failed', 'AdminUser', $admin->id);
            throw ValidationException::withMessages(['code' => 'Nieprawidłowy kod TOTP. Zeskanuj QR ponownie i spróbuj jeszcze raz.']);
        }
        RateLimiter::clear($throttleKey);

        $admin->update(['totp_enabled' => true]);

        $request->session()->forget('pending_admin_id');
        Auth::guard('admin')->login($admin);
        $request->session()->regenerate();

        $admin->update(['last_login_at' => now(), 'last_login_ip' => $request->ip()]);
        AuditLogger::log('admin.totp_setup_completed', 'AdminUser', $admin->id);

        // Recovery codes are generated right here, once, immediately after
        // MFA is first enabled — never before, so an admin can't end up
        // with valid recovery codes for a TOTP secret they never
        // confirmed. Shown exactly once via session flash (not persisted
        // anywhere in plaintext) then the admin proceeds to the dashboard.
        $rawCodes = app(RecoveryCodeService::class)->regenerate($admin);
        AuditLogger::log('admin.recovery_codes_generated', 'AdminUser', $admin->id, ['reason' => 'initial_totp_setup']);

        return redirect()->route('admin.recovery-codes.show')->with('recovery_codes', $rawCodes);
    }

    public function showRecoveryCodesOnce(Request $request)
    {
        $codes = $request->session()->pull('recovery_codes');
        abort_unless($codes, 404);
        return view('admin.auth.recovery-codes-shown', ['codes' => $codes]);
    }

    /**
     * Self-service regeneration (spec decision #5): requires the admin to
     * prove they still control their authenticator (current 6-digit TOTP)
     * before invalidating and replacing the whole set.
     */
    public function regenerateRecoveryCodes(Request $request, RecoveryCodeService $recoveryCodes)
    {
        $admin = Auth::guard('admin')->user();
        $data = $request->validate(['code' => ['required', 'string', 'size:6']]);

        // Iteration 1.1 point 8 fix: same brute-force exposure as the
        // other two TOTP checks above.
        $throttleKey = 'admin-totp-regen:' . $request->ip() . ':' . $admin->id;
        $this->throttleTotpOrFail($throttleKey);

        $google2fa = new Google2FA();
        if (!$google2fa->verifyKey($admin->totp_secret, $data['code'])) {
            RateLimiter::hit($throttleKey, 300);
            AuditLogger::log('admin.recovery_regenerate_failed_totp', 'AdminUser', $admin->id);
            throw ValidationException::withMessages(['code' => 'Nieprawidłowy kod TOTP.']);
        }
        RateLimiter::clear($throttleKey);

        $rawCodes = $recoveryCodes->regenerate($admin);
        AuditLogger::log('admin.recovery_codes_regenerated', 'AdminUser', $admin->id);

        return redirect()->route('admin.recovery-codes.show')->with('recovery_codes', $rawCodes);
    }

    public function logout(Request $request)
    {
        AuditLogger::log('admin.logout', 'AdminUser', Auth::guard('admin')->id());
        Auth::guard('admin')->logout();
        $request->session()->invalidate();
        $request->session()->regenerateToken();
        return redirect()->route('admin.login');
    }
}
