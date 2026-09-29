<?php
/**
 * POST /api/v1/mobile/session/change-password
 * body: {
 *   "username": "...",
 *   "current_password": "...",
 *   "new_password": "...",
 *   "installation_id": "..."
 * }
 *
 * Completes the same mandatory first-login password change as legacy
 * public/force-change-password.php without issuing a general mobile
 * bearer token before the requirement is satisfied.
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
$currentPassword = (string) ($body['current_password'] ?? '');
$newPassword = (string) ($body['new_password'] ?? '');
$installationId = trim((string) ($body['installation_id'] ?? ''));

if ($username === '' || $currentPassword === '' || $newPassword === '' || $installationId === '') {
    JsonResponse::error(
        'missing_fields',
        'Wymagane: username, current_password, new_password, installation_id.',
        400
    );
}

if (strlen($username) > 50 || strlen($currentPassword) > 255 || strlen($newPassword) > 255) {
    JsonResponse::error('invalid_fields', 'Nieprawidłowe dane wejściowe.', 400);
}

if (!InstallationIdValidator::isValid($installationId)) {
    JsonResponse::error('invalid_installation_id', 'installation_id musi być poprawnym UUID.', 400);
}

$ip = $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
$authenticator = new LegacyPasswordAuthenticator($conn);
$user = $authenticator->attempt($username, $currentPassword, $ip);

if ($user === null) {
    JsonResponse::error('invalid_credentials', 'Nieprawidłowa nazwa użytkownika lub hasło.', 401);
}

if ($user['password_changed'] ?? false) {
    JsonResponse::error('password_change_not_required', 'Zmiana hasła nie jest wymagana.', 409);
}

$deviceAuth = mobileapi_device_authorization_service($conn);
$deviceResult = $deviceAuth->validate($installationId);
if ($deviceResult['state'] !== 'active') {
    $httpStatus = $deviceResult['state'] === 'central_unavailable' ? 503 : 403;
    JsonResponse::error(
        'device_not_authorized',
        'Urządzenie nie jest autoryzowane do korzystania z tej parafii.',
        $httpStatus,
        ['device_state' => $deviceResult['state']]
    );
}

$newHash = password_hash($newPassword, PASSWORD_DEFAULT);
if ($newHash === false) {
    JsonResponse::error('password_hash_failed', 'Nie udało się ustawić nowego hasła.', 500);
}

$conn->begin_transaction();
try {
    $stmt = $conn->prepare(
        'UPDATE users
         SET password = ?, password_changed = 1
         WHERE id = ? AND password_changed = 0 AND is_active = 1'
    );
    $userId = (int) $user['id'];
    $stmt->bind_param('si', $newHash, $userId);
    $stmt->execute();
    $updated = $stmt->affected_rows === 1;
    $stmt->close();

    if (!$updated) {
        $conn->rollback();
        JsonResponse::error(
            'password_change_not_required',
            'Zmiana hasła została już wykonana. Zaloguj się ponownie.',
            409
        );
    }

    $tokenService = new MobileUserTokenService($conn);
    $tokenService->revokeAllForUser($userId);
    $token = $tokenService->mint($userId, $installationId);

    $conn->commit();

    JsonResponse::success([
        'token' => $token,
        'user' => [
            'id' => $userId,
            'full_name' => $user['full_name'],
            'role_id' => $user['role_id'],
        ],
    ]);
} catch (\Throwable $e) {
    $conn->rollback();
    error_log('Mobile mandatory password change failed: ' . $e->getMessage());
    JsonResponse::error('password_change_failed', 'Nie udało się zmienić hasła.', 500);
}
