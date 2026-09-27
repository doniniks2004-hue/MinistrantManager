<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Symfony\Component\HttpFoundation\Response;

/**
 * Spec decision #4: a second, stricter tier on top of `auth:admin`.
 * Registered as route middleware alias `super_admin` in bootstrap/app.php.
 * ADMIN-role users get a 403, not a redirect to login — they ARE
 * authenticated, just not authorized for this action.
 */
class EnsureSuperAdmin
{
    public function handle(Request $request, Closure $next): Response
    {
        $admin = Auth::guard('admin')->user();
        abort_if(!$admin || !$admin->isSuperAdmin(), 403, 'Ta operacja wymaga uprawnień SUPER_ADMIN.');
        return $next($request);
    }
}
