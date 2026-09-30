<?php
declare(strict_types=1);

$root = dirname(__DIR__);
$errors = [];

$profiles = glob($root . '/profiles/*.php') ?: [];
if ($profiles === []) $errors[] = 'No profiles found.';

foreach ($profiles as $file) {
    $p = require $file;
    foreach (['key','adapter_dir','required_files','required_tables','hardeners','install_meta'] as $required) {
        if (!array_key_exists($required, $p)) $errors[] = basename($file) . ": missing $required";
    }
    if (!isset($p['adapter_dir'])) continue;
    $adapter = $root . '/mobileapi-core/ParishAdapters/' . $p['adapter_dir'];
    if (!is_dir($adapter)) $errors[] = basename($file) . ': adapter directory missing';
    foreach (['bootstrap.php','config.php','session_login.php','session_change_password.php','webview_handoff.php'] as $endpoint) {
        if (!is_file($adapter . '/' . $endpoint)) $errors[] = basename($file) . ": missing adapter endpoint $endpoint";
    }
    if (isset($p['install_meta']) && !is_file($root . '/mobileapi-core/' . $p['install_meta'])) {
        $errors[] = basename($file) . ': install_meta target missing';
    }
    foreach ($p['hardeners'] ?? [] as $hardener) {
        if (!is_file($root . '/scripts/' . $hardener)) $errors[] = basename($file) . ": hardener missing: $hardener";
    }
}

$stubDir = $root . '/public_html-additions/api/mobile';
foreach (['bootstrap.php','config.php','session_login.php','session_change_password.php','webview_handoff.php'] as $stub) {
    $content = file_get_contents($stubDir . '/' . $stub) ?: '';
    if (!str_contains($content, 'ParishAdapters/dispatch.php')) $errors[] = "$stub does not use universal dispatcher";
    if (str_contains($content, 'ParishAdapters/Witosa/')) $errors[] = "$stub is hardcoded to Witosa";
}

if (!is_file($root . '/install.php')) $errors[] = 'install.php missing';
if (!is_file($root . '/rollback.php')) $errors[] = 'rollback.php missing';
if (!is_file($root . '/mobileapi-core/ParishAdapters/dispatch.php')) $errors[] = 'dispatch.php missing';

if ($errors !== []) {
    fwrite(STDERR, implode(PHP_EOL, $errors) . PHP_EOL);
    exit(1);
}

echo "UNIVERSAL INSTALLER STRUCTURE OK\n";
