<?php
declare(strict_types=1);

/**
 * Stable entrypoint used by every public stub. The installer writes
 * mobileapi-core/active-profile.php after detecting the parish variant.
 * Public URLs never need to know which adapter is active.
 */
$endpoint = defined('MOBILEAPI_ENDPOINT') ? MOBILEAPI_ENDPOINT : '';
$allowed = [
    'bootstrap.php',
    'config.php',
    'session_login.php',
    'session_change_password.php',
    'webview_handoff.php',
];

if (!in_array($endpoint, $allowed, true)) {
    http_response_code(500);
    exit('Invalid MobileAPI endpoint.');
}

$profileFile = dirname(__DIR__) . '/active-profile.php';
if (!is_file($profileFile)) {
    http_response_code(503);
    exit('MobileAPI profile is not installed.');
}

$profile = require $profileFile;
if (!is_string($profile) || !preg_match('/^[A-Za-z0-9_-]+$/', $profile)) {
    http_response_code(500);
    exit('Invalid MobileAPI profile.');
}

$target = __DIR__ . '/' . $profile . '/' . $endpoint;
if (!is_file($target)) {
    http_response_code(503);
    exit('Selected MobileAPI adapter does not provide this endpoint.');
}

require $target;
