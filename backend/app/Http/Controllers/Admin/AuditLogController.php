<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\AdminUser;
use App\Models\AuditLog;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;

/**
 * Iteration 1.1 point 14 (closing this review round): `audit_logs` was
 * already written to on every administrative action (AuditLogger::log())
 * since Iteration 1 — this controller was the missing piece to actually
 * VIEW that log.
 *
 * Access policy (spec decision #4, applied here): SUPER_ADMIN sees every
 * entry, unrestricted. ADMIN sees only entries where admin_user_id is
 * their own — enforced via a mandatory query constraint, not just a
 * hidden filter option, so an ADMIN can't work around it by fiddling with
 * query parameters.
 */
class AuditLogController extends Controller
{
    public function index(Request $request)
    {
        $actor = Auth::guard('admin')->user();
        $isSuperAdmin = $actor->isSuperAdmin();

        $query = AuditLog::query()->orderByDesc('created_at');

        if (!$isSuperAdmin) {
            // Enforced regardless of any admin_id the request tries to pass —
            // see the `if ($isSuperAdmin)` guard below, which is the ONLY
            // place admin_id filtering is honored from user input.
            $query->where('admin_user_id', $actor->id);
        }

        if ($isSuperAdmin && $request->filled('admin_id')) {
            $query->where('admin_user_id', $request->get('admin_id'));
        }

        if ($request->filled('action')) {
            $query->where('action', 'like', '%' . $request->get('action') . '%');
        }

        if ($request->filled('date_from')) {
            $query->whereDate('created_at', '>=', $request->get('date_from'));
        }

        if ($request->filled('date_to')) {
            $query->whereDate('created_at', '<=', $request->get('date_to'));
        }

        $entries = $query->paginate(50)->withQueryString();

        // Only SUPER_ADMIN gets the admin filter dropdown — an ADMIN's
        // results are already locked to themselves, so offering them a
        // picker for other admins would be misleading UI, not just a
        // harmless no-op.
        $admins = $isSuperAdmin ? AdminUser::orderBy('name')->get(['id', 'name', 'email']) : collect();

        return view('admin.audit-log.index', [
            'entries' => $entries,
            'admins' => $admins,
            'isSuperAdmin' => $isSuperAdmin,
        ]);
    }
}
