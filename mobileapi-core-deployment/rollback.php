<?php
declare(strict_types=1);

if (PHP_SAPI !== 'cli') { http_response_code(403); exit("CLI only.\n"); }
function fail(string $s): never { fwrite(STDERR, "ERROR: $s\n"); exit(1); }
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
        if (!is_dir(dirname($dst))) mkdir(dirname($dst), 0750, true);
        if (!copy($src, $dst)) throw new RuntimeException("Cannot copy $src");
        return;
    }
    if (!is_dir($src)) return;
    if (!is_dir($dst)) mkdir($dst, 0750, true);
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($src, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::SELF_FIRST);
    foreach ($it as $item) {
        $rel = substr($item->getPathname(), strlen($src) + 1);
        $target = $dst . DIRECTORY_SEPARATOR . $rel;
        if ($item->isDir()) { if (!is_dir($target)) mkdir($target, 0750, true); }
        elseif (!copy($item->getPathname(), $target)) throw new RuntimeException("Cannot copy " . $item->getPathname());
    }
}
$backup = null;
foreach ($argv as $arg) if (str_starts_with($arg, '--backup=')) $backup = substr($arg, 9);
if (!$backup || !is_file($backup . '/manifest.json')) fail('Use --backup=/path/to/mm-installer-backups/TIMESTAMP');
$manifest = json_decode((string)file_get_contents($backup . '/manifest.json'), true);
if (!is_array($manifest) || empty($manifest['target_root'])) fail('Invalid manifest.');
$target = rtrim($manifest['target_root'], '/');

// Validate the entire restore plan before removing any current files.
$targetReal = realpath($target);
if ($targetReal === false || $targetReal === DIRECTORY_SEPARATOR) fail('Invalid target root.');
$lock = fopen($targetReal . '/.mm-installer.lock', 'c');
if ($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) fail('Another installer is running.');
foreach (array_merge($manifest['created_items'] ?? [], $manifest['backup_items'] ?? []) as $rel) {
    if (!is_string($rel) || $rel === '' || str_starts_with($rel, '/')
        || str_contains($rel, "\\") || str_contains($rel, "\0")
        || in_array('..', explode('/', $rel), true) || in_array('.', explode('/', $rel), true)) {
        fail('Invalid relative path in manifest.');
    }
    $cursor = $targetReal;
    foreach (explode('/', $rel) as $segment) {
        $cursor .= '/' . $segment;
        if (is_link($cursor)) fail('Refusing symlink in restore target.');
    }
}
foreach ($manifest['backup_items'] ?? [] as $rel) {
    $src = $backup . '/files/' . $rel;
    if (!file_exists($src) || is_link($src)) fail('Missing or unsafe backup item: ' . $rel);
    if (is_dir($src)) {
        foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($src, FilesystemIterator::SKIP_DOTS)) as $item) {
            if ($item->isLink() || !$item->isReadable()) fail('Unreadable or linked backup item.');
        }
    } elseif (!is_readable($src)) fail('Unreadable backup item.');
}

foreach (array_reverse($manifest['created_items'] ?? []) as $rel) {
    removeTree($target . '/' . $rel);
}
foreach ($manifest['backup_items'] ?? [] as $rel) {
    $src = $backup . '/files/' . $rel;
    $dst = $target . '/' . $rel;
    removeTree($dst);
    copyTree($src, $dst);
}
echo "ROLLBACK FILES OK\n";
echo "Database migrations are additive and were intentionally left in place; routing/code was restored.\n";
