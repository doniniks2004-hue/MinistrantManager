<?php
declare(strict_types=1);
// Run with php -n: a failing DB double exercises the actual authenticator
// without a database or a reimplementation of its limiter.
if (class_exists('mysqli')) throw new RuntimeException('Run this test with php -n.');
class mysqli {
    public string $mode = 'missing-table';
    public function query(string $sql): object|false {
        if ($this->mode === 'missing-table') return (object)['num_rows' => 0];
        return (object)['num_rows' => 1];
    }
    public function real_escape_string(string $s): string { return $s; }
    public function prepare(string $sql): object|false {
        if (str_contains($sql, 'FROM users')) throw new RuntimeException('Password lookup bypassed failed limiter');
        return false;
    }
}
require dirname(__DIR__) . '/mobileapi-core/Auth/LegacyPasswordAuthenticator.php';
$db = new mysqli();
$auth = new MinistrantManager\MobileAPI\Auth\LegacyPasswordAuthenticator($db);
foreach (['missing-table', 'prepare-failure'] as $mode) {
    $db->mode = $mode;
    if ($auth->attempt('test', 'test-password', '127.0.0.1') !== null) {
        throw new RuntimeException('Broken limiter allowed login: ' . $mode);
    }
}
echo "LOGIN LIMITER FAIL-CLOSED OK\n";
