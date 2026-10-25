<?php
declare(strict_types=1);

function check(bool $ok, string $message): void {
    if (!$ok) throw new RuntimeException($message);
}
function put(string $path, string $text): void {
    if (!is_dir(dirname($path))) mkdir(dirname($path), 0700, true);
    file_put_contents($path, $text);
}
$root = sys_get_temp_dir() . '/mm-rollback-' . bin2hex(random_bytes(8));
$target = $root . '/target';
$backup = $root . '/backup';
$script = dirname(__DIR__) . '/rollback.php';
$manifest = ['target_root' => $target, 'created_items' => ['public_html/new.php'],
    'backup_items' => ['mobileapi-core']];
try {
    put($target . '/mobileapi-core/old.php', 'new version');
    put($target . '/mobileapi-core/new.php', 'must disappear');
    put($target . '/public_html/new.php', 'new endpoint');
    put($target . '/public_html/unrelated.php', 'keep');
    put($backup . '/files/mobileapi-core/old.php', 'old version');
    chmod($backup . '/files/mobileapi-core/old.php', 0600);
    put($backup . '/manifest.json', json_encode($manifest));
    exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($script) . ' ' . escapeshellarg('--backup=' . $backup) . ' 2>&1', $output, $code);
    check($code === 0, implode("\n", $output));
    check(file_get_contents($target . '/mobileapi-core/old.php') === 'old version', 'Old content not restored');
    check((fileperms($target . '/mobileapi-core/old.php') & 0777) === 0600, 'Private file permissions lost');
    check(!file_exists($target . '/mobileapi-core/new.php'), 'New nested file survived rollback');
    check(!file_exists($target . '/public_html/new.php'), 'New endpoint survived rollback');
    check(file_get_contents($target . '/public_html/unrelated.php') === 'keep', 'Unrelated file changed');

    put($target . '/public_html/new.php', 'keep on invalid backup');
    $manifest['backup_items'][] = 'missing.php';
    put($backup . '/manifest.json', json_encode($manifest));
    exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($script) . ' ' . escapeshellarg('--backup=' . $backup) . ' 2>&1', $output, $code);
    check($code !== 0, 'Incomplete backup accepted');
    check(file_exists($target . '/public_html/new.php'), 'Files removed before validating backup');

    $manifest['backup_items'] = ['mobileapi-core'];
    $manifest['created_items'] = ['../outside.php'];
    put($root . '/outside.php', 'keep');
    put($backup . '/manifest.json', json_encode($manifest));
    exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($script) . ' ' . escapeshellarg('--backup=' . $backup) . ' 2>&1', $output, $code);
    check($code !== 0 && file_exists($root . '/outside.php'), 'Traversal accepted');
    echo "ROLLBACK REGRESSIONS OK\n";
} finally {
    if (is_dir($root)) {
        $items = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
        foreach ($items as $item) { if ($item->isDir()) rmdir($item->getPathname()); else unlink($item->getPathname()); }
        rmdir($root);
    }
}
