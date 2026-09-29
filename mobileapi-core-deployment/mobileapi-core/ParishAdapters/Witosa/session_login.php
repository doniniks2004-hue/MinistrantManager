<?php
/**
 * POST /api/v1/mobile/session/login
 * body: { "username": "...", "password": "...", "installation_id": "..." }
 *
 * First-time (or password-based) login for the native app. Verifies
 * EXACTLY the same way `src/auth.php`'s web login does (same
 * LegacyPasswordAuthenticator — no duplicated password/rate-limit logic,
 * Iteration 2 point 2), then mints a parish-local mobile_user_token.
 *
 * Deliberately does NOT touch $_SESSION or call
 * issue_remember_token_from_central() — that's `src/auth.php`'s own,
 * separate mechanism for the existing browser/webview login continuity.
 * This endpoint is a wholly independent path for the native app; the two
 * don't need to know about each other for this vertical slice.
 */

require __DIR__ . '/wiring.php';

use MinistrantManager\MobileAPI\Auth\LegacyPasswordAuthenticator;
use MinistrantManager\MobileAPI\Auth\InstallationIdValidator;
use MinistrantManager\MobileAPI\Auth\MobileUserTokenService;
use MinistrantManager\MobileAPI\Http\JsonResponse;

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    JsonResponse::error('method_not_allowed', 'Wymagane POST.', 405);
}

$body = mobileapi_read_json_body();
$username = trim((string) ($body['username'] ?? ''));
$password = (string) ($body['password'] ?? '');
$installationId = trim((string) ($body['installation_id'] ?? ''));

if ($username === '' || $password === '' || $installationId === '') {
    JsonResponse::error('missing_fields', 'Wymagane: username, password, installation_id.', 400);
}

if (!InstallationIdValidator::isValid($installationId)) {
    JsonResponse::error('invalid_installation_id', 'installation_id musi być poprawnym UUID.', 400);
}

$ip = $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';

$authenticator = new LegacyPasswordAuthenticator($conn);
$user = $authenticator->attempt($username, $password, $ip);

if ($user === null) {
    // Deliberately the same generic message/status for "wrong password",
    // "unknown username", and "rate limited" — see
    // LegacyPasswordAuthenticator's docblock for why.
    JsonResponse::error('invalid_credentials', 'Nieprawidłowa nazwa użytkownika lub hasło.', 401);
}

// Device-control-plane milestone (review round point 4): THE first
// mandatory enforcement point. Flow exactly as specified: local user
// check first (above, cheap, no network) -> central device validation
// -> only THEN mint a token. A device that's revoked/parish-disabled/
// unknown to app.ministrant.eu/mismatched to another parish never gets
// a mobile_user_token, no matter how correct the password was.
$deviceAuth = mobileapi_device_authorization_service($conn);
$deviceResult = $deviceAuth->validate($installationId);

if ($deviceResult['state'] !== 'active') {
    // Review round point 8 (Flutter side): this is a DIFFERENT failure
    // from invalid_credentials — the client must show neither "zły
    // login/hasło" nor "problem z internetem", but its own distinct
    // "urządzenie nie jest autoryzowane" state, and re-run the full
    // central device-status flow rather than assume a network hiccup.
    // 'central_unavailable' gets a DIFFERENT HTTP status (503) than the
    // other four (403) — the client story is the same either way
    // ("try again, this isn't your fault"), but a 503 is the honest
    // signal that WE couldn't confirm anything at all, vs the other
    // four where we affirmatively DID get an answer and it was no.
    $httpStatus = $deviceResult['state'] === 'central_unavailable' ? 503 : 403;
    JsonResponse::error('device_not_authorized', 'Urządzenie nie jest autoryzowane do korzystania z tej parafii.', $httpStatus, [
        'device_state' => $deviceResult['state'],
    ]);
}

if (!($user['password_changed'] ?? false)) {
    JsonResponse::error(
        'password_change_required',
        'Przy pierwszym logowaniu musisz ustawić nowe hasło.',
        428
    );
}

$tokenService = new MobileUserTokenService($conn);
$token = $tokenService->mint($user['id'], $installationId);

JsonResponse::success([
    'token' => $token,
    'user' => [
        'id' => $user['id'],
        'full_name' => $user['full_name'],
        'role_id' => $user['role_id'],
    ],
]);
