<?php
declare(strict_types=1);
require __DIR__ . '/../scripts/routing_config.php';
$root = dirname(__DIR__);
$snippet = file_get_contents($root . '/public_html-additions/htaccess-snippet.txt');
$legacy = "RewriteEngine On\nRewriteRule ^api/(.*)$ legacy.php [L,QSA]\n";
$old = "# BEGIN MINISTRANT MANAGER MOBILEAPI\nRewriteRule ^api/v1/mobile/config$ api/mobile/config.php [L]\n# END MINISTRANT MANAGER MOBILEAPI\n";
$first = canonicalMobileRouting($old . $legacy . $old, $snippet);
$second = canonicalMobileRouting($first, $snippet);
if ($first !== $second || substr_count($second, '# BEGIN MINISTRANT MANAGER MOBILEAPI') !== 1
    || !str_ends_with($second, $legacy) || str_contains($second, 'api/mobile/config.php')) {
    throw new RuntimeException('Routing update must be idempotent and precede preserved legacy rules.');
}
foreach (['bootstrap','config','session-login','session-change-password','webview-handoff'] as $endpoint) {
    $proxy = 'mm-mobile-' . $endpoint . '.php';
    if (!is_file($root . '/public_html-additions/' . $proxy) || !str_contains($snippet, $proxy . ' [END,QSA]')
        || !str_contains(file_get_contents($root . '/install.php'), "'public_html/" . $proxy . "'")) {
        throw new RuntimeException('Missing routing, proxy, or rollback entry: ' . $proxy);
    }
}
if (!preg_match('/\^\(\?:install\|reset\|upd\|fix\|receiver\)\\\\\.php\$/', $snippet)) {
    throw new RuntimeException('Maintenance script extension must use a single regex escape.');
}
foreach (['mobileapi-core', 'public_html-additions'] as $directory) {
    foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root . '/' . $directory)) as $file) {
        if ($file->isFile() && $file->getExtension() === 'php' && str_contains(file_get_contents($file->getPathname()), '->get_result(')) {
            throw new RuntimeException('mysqlnd-dependent result fetch: ' . $file->getPathname());
        }
    }
}
echo "ROUTING, ROLLBACK AND MYSQLND COMPATIBILITY OK\n";
