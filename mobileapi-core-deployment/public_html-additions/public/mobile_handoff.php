<?php
/**
 * GET /public/mobile_handoff.php?ticket=...
 *
 * Hybrid dashboard milestone (review round, point 18): the ONLY thing a
 * WebView ever navigates to with a ticket in the URL — the ticket is a
 * random, single-use, server-verified credential that authorizes
 * loading exactly one legacy module once, NEVER mobile_user_token
 * itself (that never leaves the app / never appears in any URL/JS/
 * WebView, per the explicit rule).
 *
 * Sets the PHP session EXACTLY like a normal password login (see
 * src/auth.php) — session_regenerate_id + the same five session keys —
 * so every existing legacy page's `$_SESSION['user_id']` check works
 * completely unchanged. Then redirects (302) to the path that was fixed
 * at TICKET-MINT time server-side — never to a path taken from this
 * request's own query string, so a tampered URL can't redirect
 * elsewhere.
 */

require_once __DIR__ . '/../config/database.php';
require_once __DIR__ . '/../../mobileapi-core/ParishAdapters/autoload.php';

use MinistrantManager\MobileAPI\Auth\WebviewHandoffTicketService;

function handoff_fail(string $message): never
{
    http_response_code(403);
    header('Content-Type: text/html; charset=utf-8');
    echo '<!DOCTYPE html><html lang="pl"><head><meta charset="utf-8"><title>Sesja wygasła</title></head><body style="font-family:sans-serif;text-align:center;padding:60px 20px;">'
        . '<h2>Nie udało się otworzyć modułu</h2><p>' . htmlspecialchars($message) . '</p>'
        . '<p>Wróć do aplikacji i spróbuj ponownie.</p></body></html>';
    exit;
}

$ticket = $_GET['ticket'] ?? '';
if (!is_string($ticket) || $ticket === '') {
    handoff_fail('Brak biletu dostępu.');
}

$service = new WebviewHandoffTicketService($conn);
$consumed = $service->consume($ticket);

if ($consumed === null) {
    handoff_fail('Bilet dostępu jest nieprawidłowy, wygasł, lub został już użyty.');
}

$stmt = $conn->prepare('SELECT id, full_name, role_id, password_changed, is_active FROM users WHERE id = ?');
$stmt->bind_param('i', $consumed['user_id']);
$stmt->execute();
$user = $stmt->get_result()->fetch_assoc();
$stmt->close();

if ($user === null || (int) $user['is_active'] !== 1) {
    handoff_fail('Konto jest nieaktywne.');
}
if ((int) $user['password_changed'] !== 1) {
    handoff_fail('Wymagana jest zmiana hasła w aplikacji.');
}

// Same session-regeneration pattern as src/auth.php's password login.
if (session_status() === PHP_SESSION_ACTIVE) {
    $sessionData = $_SESSION;
    session_regenerate_id(true);
    $_SESSION = $sessionData;
}

$_SESSION['user_id'] = (int) $user['id'];
$_SESSION['user_full_name'] = $user['full_name'];
$_SESSION['user_role_id'] = (int) $user['role_id'];
$_SESSION['login_time'] = time();
$_SESSION['last_activity'] = time();
$_SESSION['user_ip'] = $_SERVER['REMOTE_ADDR'] ?? '';
$_SESSION['last_regeneration'] = time();

// The target path was fixed server-side at ticket-mint time
// (webview_handoff.php validated it against webview_path_allowlist())
// — never taken from this request's own query string.
header('Location: ' . $consumed['target_path']);
exit;
