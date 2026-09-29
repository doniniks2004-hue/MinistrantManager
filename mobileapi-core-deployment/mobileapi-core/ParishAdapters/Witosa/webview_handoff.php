<?php
/**
 * POST /api/v1/mobile/webview/handoff
 * headers: Authorization: Bearer <mobile_user_token>, X-Installation-Id: ...
 * body: {"path": "/public/triduum.php"}
 *
 * Hybrid dashboard milestone (review round, point 18): mints a short-
 * lived, single-use ticket that lets the ALREADY mobile-authenticated
 * caller open `path` in a WebView without a second login. The ticket —
 * never mobile_user_token itself — is what goes into the WebView's URL.
 *
 * Review round fix (real gap): `path` must be a KNOWN module in
 * webview_module_registry() — 400 otherwise — AND the caller's role
 * must satisfy that module's `required_role` — 403 otherwise. The
 * OLD version only checked the path against a flat allowlist with no
 * role check at all, which meant a Ministrant who knew (or guessed) an
 * admin-only path like /public/users.php could mint a perfectly valid
 * ticket for it — path-only validation was never enough on its own.
 */

require __DIR__ . '/wiring.php';
require __DIR__ . '/modules_builder.php';

use MinistrantManager\MobileAPI\Auth\WebviewHandoffTicketService;
use MinistrantManager\MobileAPI\Http\JsonResponse;
use function MinistrantManager\MobileAPI\ParishAdapters\Witosa\webview_module_registry;

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    JsonResponse::error('method_not_allowed', 'Wymagane POST.', 405);
}

$ctx = mobileapi_device_context();
$user = mobileapi_require_user_auth($conn, $ctx);

// Device-control-plane milestone (review round point 7): "DEVICE
// AUTHORIZED AND USER AUTHORIZED FOR MODULE" — two independent
// conditions, both required. mobileapi_require_user_auth() above only
// proves the mobile_user_token itself is valid and bound to this
// installation_id (MobileUserTokenService) — it does NOT re-confirm
// with app.ministrant.eu that the DEVICE is still authorized right now.
// Uses the SAME cached/leased DeviceAuthorizationService as
// session_login.php — review round point 5: this does NOT hit central
// on every handoff request, it mostly reads the existing lease.
$deviceAuth = mobileapi_device_authorization_service($conn);
$deviceResult = $deviceAuth->validate($ctx->installationId);
if ($deviceResult['state'] !== 'active') {
    $httpStatus = $deviceResult['state'] === 'central_unavailable' ? 503 : 403;
    JsonResponse::error('device_not_authorized', 'Urządzenie nie jest autoryzowane do korzystania z tej parafii.', $httpStatus, [
        'device_state' => $deviceResult['state'],
    ]);
}

$body = mobileapi_read_json_body();
$path = $body['path'] ?? '';

$registry = webview_module_registry();
$module = null;
foreach ($registry as $def) {
    if ($def['path'] === $path) {
        $module = $def;
        break;
    }
}

if (!is_string($path) || $module === null) {
    JsonResponse::error('invalid_path', 'Nieznana lub niedozwolona ścieżka modułu.', 400);
}

// Review round fix: the actual permission check — a role mismatch is a
// DIFFERENT failure than "path doesn't exist" (403, not 400), so the
// client can eventually tell "you don't have access" apart from "this
// module doesn't exist on this parish".
$requiredRole = $module['required_role'];
if ($requiredRole !== null && !in_array($user->roleId, $requiredRole, true)) {
    JsonResponse::error('forbidden', 'Brak uprawnień do tego modułu.', 403);
}

$service = new WebviewHandoffTicketService($conn);
$result = $service->mint($user->userId, $ctx->installationId, $path);

JsonResponse::success([
    'ticket' => $result['ticket'],
    'expires_at' => $result['expires_at'],
]);
