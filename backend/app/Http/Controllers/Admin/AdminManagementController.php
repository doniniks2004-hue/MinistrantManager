<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\AdminUser;
use App\Services\AuditLogger;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Hash;
use Illuminate\Validation\ValidationException;

/**
 * SUPER_ADMIN-only console for managing other admin accounts (spec
 * decision #4). Every mutating action here re-checks the specific
 * AdminUser::can*() rule (not just the blanket `super_admin` route
 * middleware) because some actions are restricted even between two
 * SUPER_ADMINs (e.g. you can never deactivate the last active one).
 */
class AdminManagementController extends Controller
{
    public function index()
    {
        $admins = AdminUser::orderBy('name')->get();
        return view('admin.admins.index', compact('admins'));
    }

    public function create()
    {
        return view('admin.admins.create');
    }

    public function store(Request $request)
    {
        $data = $request->validate([
            'name' => ['required', 'string', 'max:255'],
            'email' => ['required', 'email', 'unique:admin_users,email'],
            'password' => ['required', 'string', 'min:12'],
            'role' => ['required', 'in:SUPER_ADMIN,ADMIN'],
        ]);

        $admin = AdminUser::create([
            'name' => $data['name'],
            'email' => $data['email'],
            'password' => Hash::make($data['password']),
            'role' => $data['role'],
            'is_active' => true,
            // totp_enabled stays false — this admin is forced through
            // admin.totp.setup on their very first login, same as any
            // other freshly created account. There is no way to create
            // an admin account that skips MFA.
        ]);

        AuditLogger::log('admin.created', 'AdminUser', $admin->id, ['role' => $admin->role]);

        return redirect()->route('admin.admins.index')->with('status', "Utworzono konto {$admin->email}.");
    }

    public function updateRole(Request $request, AdminUser $admin)
    {
        $data = $request->validate(['role' => ['required', 'in:SUPER_ADMIN,ADMIN']]);
        $actor = Auth::guard('admin')->user();

        if (!$actor->canChangeRoleOf($admin, $data['role'])) {
            abort(403, 'Nie można wykonać tej zmiany roli.');
        }

        // Never allow demoting the last active SUPER_ADMIN, even by
        // someone else — otherwise the whole panel becomes unmanageable.
        if ($admin->isSuperAdmin() && $data['role'] !== 'SUPER_ADMIN'
            && AdminUser::where('role', 'SUPER_ADMIN')->where('is_active', true)->count() <= 1) {
            throw ValidationException::withMessages(['role' => 'Nie można odebrać roli ostatniemu aktywnemu SUPER_ADMINOWI.']);
        }

        $admin->update(['role' => $data['role']]);
        AuditLogger::log('admin.role_changed', 'AdminUser', $admin->id, ['new_role' => $data['role']]);

        return back()->with('status', "Zmieniono rolę {$admin->email} na {$data['role']}.");
    }

    public function deactivate(AdminUser $admin)
    {
        $actor = Auth::guard('admin')->user();
        abort_unless($actor->canDeactivate($admin), 403, 'Nie można dezaktywować tego konta.');

        $admin->update(['is_active' => false]);
        AuditLogger::log('admin.deactivated', 'AdminUser', $admin->id);

        return back()->with('status', "Konto {$admin->email} zostało dezaktywowane.");
    }

    public function reactivate(AdminUser $admin)
    {
        $actor = Auth::guard('admin')->user();
        abort_unless($actor->isSuperAdmin(), 403);

        $admin->update(['is_active' => true]);
        AuditLogger::log('admin.reactivated', 'AdminUser', $admin->id);

        return back()->with('status', "Konto {$admin->email} zostało ponownie aktywowane.");
    }

    /**
     * Spec §6 / decision #4: forcibly clears the target's TOTP secret and
     * ALL their recovery codes, and flips totp_enabled back off — the next
     * time they log in with the right password, they're routed straight
     * into admin.totp.setup again, exactly like a brand new account.
     * SUPER_ADMIN only, and never on another SUPER_ADMIN unless the actor
     * also is one (see AdminUser::canResetMfaOf()).
     */
    public function resetMfa(AdminUser $admin)
    {
        $actor = Auth::guard('admin')->user();
        abort_unless($actor->canResetMfaOf($admin), 403, 'Nie można zresetować MFA tego konta.');

        $admin->recoveryCodes()->delete();
        $admin->update(['totp_secret' => null, 'totp_enabled' => false]);

        AuditLogger::log('admin.mfa_reset', 'AdminUser', $admin->id, ['performed_by' => $actor->email]);

        return back()->with('status', "MFA konta {$admin->email} zostało zresetowane. Przy następnym logowaniu skonfiguruje je od nowa.");
    }
}
