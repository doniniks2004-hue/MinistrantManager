<?php
declare(strict_types=1);
require dirname(__DIR__) . '/mobileapi-core/Auth/LegacyPasswordAuthenticator.php';
function check(bool $ok, string $why): void { if (!$ok) throw new RuntimeException($why); }
$db = new mysqli('127.0.0.1', 'root', '', 'ministrant_mobile_test', 3306);
$db->query('CREATE TABLE users (id INT PRIMARY KEY, username VARCHAR(50), password VARCHAR(255), role_id INT, full_name VARCHAR(255), password_changed INT, is_active INT)');
$hash = password_hash('test-password', PASSWORD_BCRYPT);
$stmt = $db->prepare('INSERT INTO users VALUES (1, ?, ?, 5, ?, 1, 1)');
$username = 'test'; $name = 'Test';
$stmt->bind_param('sss', $username, $hash, $name); $stmt->execute();
$auth = new MinistrantManager\MobileAPI\Auth\LegacyPasswordAuthenticator($db);
check($auth->attempt('test', 'test-password', '127.0.0.1') === null, 'Missing limiter must deny login');
$sql = file_get_contents(dirname(__DIR__) . '/migrations/006_login_attempts.sql');
$db->query($sql);
check($auth->attempt('test', 'test-password', '127.0.0.1')['id'] === 1, 'Migration must restore legitimate login');
for ($i = 0; $i < 6; $i++) {
    check($auth->attempt('test', 'test-password', '127.0.0.1') !== null, 'Successful logins must not consume failed budget');
}
for ($i = 0; $i < 5; $i++) {
    check($auth->attempt('test', 'wrong-password', '127.0.0.1') === null, 'Wrong password accepted');
}
check($auth->attempt('test', 'test-password', '127.0.0.1') === null, 'Lockout must precede password validation');
$db->query('DELETE FROM login_attempts');
$db->query('ALTER TABLE login_attempts DROP COLUMN was_successful');
check($auth->attempt('test', 'test-password', '127.0.0.1') !== null, 'Old schema no longer supported');
$db->query($sql); // IF NOT EXISTS must preserve older parish schemas.
check($auth->attempt('test', 'test-password', '127.0.0.1') !== null, 'Migration must remain idempotent');
echo "MYSQL LOGIN LIMITER AND MIGRATION OK\n";
