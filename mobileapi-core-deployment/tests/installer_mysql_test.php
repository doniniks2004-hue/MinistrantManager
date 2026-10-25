<?php
declare(strict_types=1);
// Isolated CI database and filesystem: never targets a real parish.
$root = sys_get_temp_dir() . '/mm-install-' . bin2hex(random_bytes(8));
mkdir($root . '/public_html/config', 0700, true);
$db = new mysqli('127.0.0.1', 'root', '', '', 3306);
$db->query('CREATE DATABASE ministrant_installer_test');
$db->select_db('ministrant_installer_test');
foreach (['users', 'events', 'schedule', 'announcements'] as $table) {
    $db->query("CREATE TABLE $table (id INT NOT NULL PRIMARY KEY) ENGINE=InnoDB");
}
$config = <<<'CONFIG'
<?php
$conn = new mysqli('127.0.0.1', 'root', '', 'ministrant_installer_test', 3306);
CONFIG;
file_put_contents($root . '/public_html/config/database.php', $config);
$script = dirname(__DIR__) . '/install.php';
putenv('MOBILE_INTERNAL_API_SECRET=' . bin2hex(random_bytes(32)));
try {
    for ($i = 0; $i < 2; $i++) {
        $output = [];
        exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($script) . ' ' . escapeshellarg('--target=' . $root) . ' 2>&1', $output, $code);
        if ($code !== 0) throw new RuntimeException(implode("\n", $output));
        if (!is_file($root . '/public_html/mm-mobile-session-login.php')) throw new RuntimeException('Endpoint not installed');
        if ($db->query('SELECT schema_version FROM mobile_meta WHERE id=1')->num_rows !== 1) throw new RuntimeException('Metadata not installed');
        if ($db->query("SHOW COLUMNS FROM device_authorization_cache LIKE 'offline_lease_hours'")->num_rows !== 1) throw new RuntimeException('Lease migration missing');
        if ($db->query("SHOW TABLES LIKE 'login_attempts'")->num_rows !== 1) throw new RuntimeException('Login limiter missing');
    }
    echo "MYSQL FRESH INSTALL AND REINSTALL OK\n";
} finally {
    putenv('MOBILE_INTERNAL_API_SECRET');
    $db->query('DROP DATABASE ministrant_installer_test');
    $items = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($items as $item) { if ($item->isDir()) rmdir($item->getPathname()); else unlink($item->getPathname()); }
    rmdir($root);
}
