<?php
declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    http_response_code(403);
    exit("CLI only.\n");
}

function out(string $s=''): void { echo $s . PHP_EOL; }
function fail(string $s): never { fwrite(STDERR, "ERROR: $s\n"); exit(1); }
function argValue(array $argv, string $name): ?string {
    foreach ($argv as $arg) {
        if (str_starts_with($arg, "--$name=")) return substr($arg, strlen($name) + 3);
    }
    return null;
}
function hasArg(array $argv, string $name): bool { return in_array("--$name", $argv, true); }
function removeTree(string $path): void {
    if (is_file($path) || is_link($path)) { @unlink($path); return; }
    if (!is_dir($path)) return;
    $it = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($it as $item) {
        if ($item->isDir()) @rmdir($item->getPathname());
        else @unlink($item->getPathname());
    }
    @rmdir($path);
}
function copyTree(string $src, string $dst): void {
    if (is_file($src)) {
        if (!is_dir(dirname($dst)) && !mkdir(dirname($dst), 0750, true) && !is_dir(dirname($dst))) {
            throw new RuntimeException("Cannot create " . dirname($dst));
        }
        if (!copy($src, $dst)) throw new RuntimeException("Cannot copy $src");
        return;
    }
    if (!is_dir($src)) return;
    if (!is_dir($dst) && !mkdir($dst, 0750, true) && !is_dir($dst)) throw new RuntimeException("Cannot create $dst");
    $it = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($src, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::SELF_FIRST
    );
    foreach ($it as $item) {
        $rel = substr($item->getPathname(), strlen($src) + 1);
        $target = $dst . DIRECTORY_SEPARATOR . $rel;
        if ($item->isDir()) {
            if (!is_dir($target) && !mkdir($target, 0750, true) && !is_dir($target)) throw new RuntimeException("Cannot create $target");
        } else {
            if (!copy($item->getPathname(), $target)) throw new RuntimeException("Cannot copy " . $item->getPathname());
        }
    }
}
function runPhp(string $file): void {
    $cmd = escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($file);
    passthru($cmd, $code);
    if ($code !== 0) fail("Command failed ($code): $file");
}
function hiddenPrompt(string $label): string {
    fwrite(STDOUT, $label);
    $stty = trim((string) shell_exec('command -v stty 2>/dev/null'));
    if ($stty !== '') shell_exec('stty -echo');
    $value = trim((string) fgets(STDIN));
    if ($stty !== '') { shell_exec('stty echo'); fwrite(STDOUT, PHP_EOL); }
    return $value;
}
function runSqlFile(mysqli $conn, string $file): void {
    $sql = file_get_contents($file);
    if ($sql === false) fail("Cannot read migration $file");
    if (!$conn->multi_query($sql)) fail("Migration failed: " . $conn->error);
    do {
        if ($result = $conn->store_result()) $result->free();
        if (!$conn->more_results()) break;
    } while ($conn->next_result());
    if ($conn->errno) fail("Migration failed: " . $conn->error);
}

$packageRoot = __DIR__;
$dryRun = hasArg($argv, 'dry-run');
$requestedProfile = argValue($argv, 'profile') ?? 'auto';
$targetRoot = argValue($argv, 'target');

if ($targetRoot === null) {
    if (is_dir($packageRoot . '/public_html')) $targetRoot = $packageRoot;
    elseif (is_dir(dirname($packageRoot) . '/public_html')) $targetRoot = dirname($packageRoot);
}
if ($targetRoot === null) fail("Cannot find public_html. Use --target=/home/user");
$targetRoot = rtrim(realpath($targetRoot) ?: $targetRoot, DIRECTORY_SEPARATOR);
$publicRoot = $targetRoot . '/public_html';
$dbConfig = $publicRoot . '/config/database.php';
if (!is_file($dbConfig)) fail("Missing $dbConfig");

out("=== Ministrant Manager Universal Parish Installer v1 ===");
out("Target: $targetRoot");
out("Mode: " . ($dryRun ? 'DRY RUN' : 'INSTALL'));

require $dbConfig;
if (!isset($conn) || !($conn instanceof mysqli)) fail("config/database.php did not provide mysqli \$conn");

$profiles = [];
foreach (glob($packageRoot . '/profiles/*.php') ?: [] as $profileFile) {
    $p = require $profileFile;
    if (is_array($p) && isset($p['key'])) $profiles[$p['key']] = $p;
}
if ($profiles === []) fail('No installer profiles found.');

$matches = [];
foreach ($profiles as $key => $profile) {
    $ok = true;
    foreach ($profile['required_files'] ?? [] as $rel) {
        if (!is_file($publicRoot . '/' . $rel)) { $ok = false; break; }
    }
    if ($ok) {
        foreach ($profile['required_tables'] ?? [] as $table) {
            $safe = $conn->real_escape_string($table);
            $res = $conn->query("SHOW TABLES LIKE '$safe'");
            if (!$res || $res->num_rows === 0) { $ok = false; break; }
        }
    }
    if ($ok) $matches[] = $key;
}

if ($requestedProfile !== 'auto') {
    if (!isset($profiles[$requestedProfile])) fail("Unknown profile: $requestedProfile");
    if (!in_array($requestedProfile, $matches, true)) fail("Profile $requestedProfile does not match this parish; refusing unsafe install.");
    $profileKey = $requestedProfile;
} else {
    if (count($matches) === 0) fail('No known parish profile matched. Installer stopped without changes.');
    if (count($matches) > 1) fail('More than one profile matched: ' . implode(', ', $matches) . '. Use --profile=...');
    $profileKey = $matches[0];
}
$profile = $profiles[$profileKey];
out("Detected profile: {$profile['label']} [$profileKey]");

if ($dryRun) {
    out('DRY RUN OK: profile recognized; no files/database were changed.');
    exit(0);
}

$secretPath = $publicRoot . '/config/mobile_internal_api_secret.php';
$secret = getenv('MOBILE_INTERNAL_API_SECRET') ?: '';
if ($secret === '' && is_file($secretPath)) {
    $existing = file_get_contents($secretPath) ?: '';
    if (preg_match("/define\(['\"]MOBILE_INTERNAL_API_SECRET['\"],\s*['\"]([^'\"]+)['\"]\)/", $existing, $m)
        && $m[1] !== 'REPLACE_WITH_REAL_PER_PARISH_SECRET_FROM_ADMIN_PANEL') {
        $secret = $m[1];
    }
}
if ($secret === '') $secret = hiddenPrompt('MOBILE_INTERNAL_API_SECRET for this parish: ');
if ($secret === '' || strlen($secret) < 24) fail('Secret is missing or too short.');

$stamp = date('Ymd_His');
$backupRoot = $targetRoot . '/mm-installer-backups/' . $stamp;
if (!mkdir($backupRoot, 0700, true) && !is_dir($backupRoot)) fail("Cannot create backup $backupRoot");

$backupItems = [];
$createdItems = [];
$protect = [
    'mobileapi-core',
    'public_html/api/mobile',
    'public_html/public/mobile_handoff.php',
    'public_html/config/mobile_internal_api_secret.php',
    'public_html/.htaccess',
];
foreach ($profile['legacy_backup_files'] ?? [] as $legacyRel) {
    $protect[] = 'public_html/' . ltrim($legacyRel, '/');
}
$protect = array_values(array_unique($protect));
foreach ($protect as $rel) {
    $src = $targetRoot . '/' . $rel;
    if (file_exists($src)) {
        copyTree($src, $backupRoot . '/files/' . $rel);
        $backupItems[] = $rel;
    } else {
        $createdItems[] = $rel;
    }
}
out("Backup: $backupRoot");

$GLOBALS['mm_install_complete'] = false;
register_shutdown_function(static function () use ($targetRoot, $backupRoot, $backupItems, $createdItems): void {
    if (($GLOBALS['mm_install_complete'] ?? false) === true) return;
    fwrite(STDERR, "\nINSTALL FAILED — restoring file snapshot automatically...\n");
    foreach (array_reverse($createdItems) as $rel) removeTree($targetRoot . '/' . $rel);
    foreach ($backupItems as $rel) {
        $src = $backupRoot . '/files/' . $rel;
        $dst = $targetRoot . '/' . $rel;
        removeTree($dst);
        copyTree($src, $dst);
    }
    fwrite(STDERR, "FILE ROLLBACK OK. Additive DB migrations, if already applied, were intentionally left in place.\n");
});

// Run profile hardening BEFORE MobileAPI migrations. If the parish has
// drifted from the audited baseline, the hardener fails closed here and
// the snapshot above restores any touched file before DB changes begin.
foreach ($profile['hardeners'] ?? [] as $script) {
    $src = $packageRoot . '/scripts/' . $script;
    $dst = $targetRoot . '/' . $script;
    copy($src, $dst);
    runPhp($dst);
}

// Stage the new core first, then swap the directory. Existing public
// endpoints never observe a half-copied MobileAPI tree.
$stagedCore = $targetRoot . '/mobileapi-core.__new__';
removeTree($stagedCore);
copyTree($packageRoot . '/mobileapi-core', $stagedCore);
file_put_contents($stagedCore . '/active-profile.php', "<?php\nreturn " . var_export($profile['adapter_dir'], true) . ";\n");
$oldCore = $targetRoot . '/mobileapi-core.__old__';
removeTree($oldCore);
if (is_dir($targetRoot . '/mobileapi-core') && !rename($targetRoot . '/mobileapi-core', $oldCore)) {
    fail('Cannot stage existing mobileapi-core for atomic swap.');
}
if (!rename($stagedCore, $targetRoot . '/mobileapi-core')) {
    if (is_dir($oldCore)) @rename($oldCore, $targetRoot . '/mobileapi-core');
    fail('Cannot activate staged mobileapi-core.');
}

copyTree($packageRoot . '/public_html-additions/api/mobile', $publicRoot . '/api/mobile');
copyTree($packageRoot . '/public_html-additions/public/mobile_handoff.php', $publicRoot . '/public/mobile_handoff.php');

$secretPhp = "<?php\ndefine('MOBILE_CENTRAL_BASE_URL', 'https://app.ministrant.eu');\ndefine('MOBILE_INTERNAL_API_SECRET', " . var_export($secret, true) . ");\n";
if (file_put_contents($secretPath, $secretPhp) === false) fail('Cannot write parish secret config.');
chmod($secretPath, 0600);

$htaccess = $publicRoot . '/.htaccess';
$snippet = file_get_contents($packageRoot . '/public_html-additions/htaccess-snippet.txt');
$currentHt = is_file($htaccess) ? (file_get_contents($htaccess) ?: '') : '';
$marker = '# BEGIN MINISTRANT MANAGER MOBILEAPI';
$endMarker = '# END MINISTRANT MANAGER MOBILEAPI';

// Canonicalize the MobileAPI block on every install/update. Legacy parish
// builds may already contain an older/duplicate block; leaving it in place
// is unsafe because an earlier legacy API catch-all can swallow /api/v1/mobile/*.
$blockPattern = '/# BEGIN MINISTRANT MANAGER MOBILEAPI.*?# END MINISTRANT MANAGER MOBILEAPI\s*/s';
$currentHt = preg_replace($blockPattern, '', $currentHt) ?? $currentHt;
$mobileBlock = $marker . "\n" . trim((string)$snippet) . "\n" . $endMarker . "\n\n";
file_put_contents($htaccess, $mobileBlock . ltrim($currentHt));

// Root-level proxies deliberately bypass the legacy ^api/(.*) router.
foreach ([
    'mm-mobile-bootstrap.php',
    'mm-mobile-config.php',
    'mm-mobile-session-login.php',
    'mm-mobile-session-change-password.php',
    'mm-mobile-webview-handoff.php',
] as $proxy) {
    copy($packageRoot . '/public_html-additions/' . $proxy, $publicRoot . '/' . $proxy);
}

copy($packageRoot . '/scripts/preflight.php', $targetRoot . '/preflight.php');
runPhp($targetRoot . '/preflight.php');

foreach (glob($packageRoot . '/migrations/*.sql') ?: [] as $migration) {
    out('Migration: ' . basename($migration));
    runSqlFile($conn, $migration);
}

$metaInstaller = $targetRoot . '/mobileapi-core/' . $profile['install_meta'];
runPhp($metaInstaller);

$manifest = [
    'installer_version' => 1,
    'installed_at' => date(DATE_ATOM),
    'profile' => $profileKey,
    'target_root' => $targetRoot,
    'backup_items' => $backupItems,
    'created_items' => $createdItems,
];
file_put_contents($backupRoot . '/manifest.json', json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));

// The old core is no longer needed after every installation step passed.
removeTree($oldCore);
$GLOBALS['mm_install_complete'] = true;

out();
out('INSTALL OK');
out("Profile: $profileKey");
out("Rollback: php " . $packageRoot . "/rollback.php --backup=$backupRoot");
out('Next: run smoke/acceptance against the parish URL.');
