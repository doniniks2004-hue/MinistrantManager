<?php
declare(strict_types=1);

if (PHP_SAPI !== 'cli') { http_response_code(403); exit("CLI only.\n"); }
function fail(string $s): never { fwrite(STDERR, "ERROR: $s\n"); exit(1); }
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
        else copy($item->getPathname(), $target);
    }
}
$backup = null;
foreach ($argv as $arg) if (str_starts_with($arg, '--backup=')) $backup = substr($arg, 9);
if (!$backup || !is_file($backup . '/manifest.json')) fail('Use --backup=/path/to/mm-installer-backups/TIMESTAMP');
$manifest = json_decode((string)file_get_contents($backup . '/manifest.json'), true);
if (!is_array($manifest) || empty($manifest['target_root'])) fail('Invalid manifest.');
$target = rtrim($manifest['target_root'], '/');

foreach (array_reverse($manifest['created_items'] ?? []) as $rel) {
    $path = $target . '/' . $rel;
    if (is_file($path) || is_link($path)) @unlink($path);
}
foreach ($manifest['backup_items'] ?? [] as $rel) {
    $src = $backup . '/files/' . $rel;
    $dst = $target . '/' . $rel;
    copyTree($src, $dst);
}
echo "ROLLBACK FILES OK\n";
echo "Database migrations are additive and were intentionally left in place; routing/code was restored.\n";
