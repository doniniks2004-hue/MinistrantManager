<?php
declare(strict_types=1);

/**
 * The diagnostics script must (1) stay in step with the repository, (2) report
 * what it is meant to, and (3) be unable to print secrets or personal data.
 */
require __DIR__ . '/../scripts/diagnose_handoff.php';

$repo = dirname(__DIR__);
$failures = [];
$check = static function (bool $ok, string $what) use (&$failures): void {
    if (!$ok) $failures[] = $what;
};

// Where each expected file lives in this repository.
$inRepo = static function (string $deployed) use ($repo): string {
    $deployed = str_replace('{profile}', 'Witosa', $deployed);
    if (str_starts_with($deployed, 'public_html/')) {
        return $repo . '/public_html-additions/' . substr($deployed, strlen('public_html/'));
    }
    return $repo . '/' . $deployed;
};

// 1. The embedded hashes are the repository's files RIGHT NOW. If a handoff
//    file changes, this fails until the script's table is regenerated.
foreach (MM_DIAG_EXPECTED as $deployed => $sha) {
    $file = $inRepo($deployed);
    $check(is_file($file), "expected file is missing from the repository: $deployed");
    $check(is_file($file) && hash_file('sha256', $file) === $sha, "stale expected hash (regenerate the table): $deployed");
}
$snippet = trim((string) file_get_contents($repo . '/public_html-additions/htaccess-snippet.txt'));
$check(hash('sha256', $snippet) === MM_DIAG_ROUTING_BLOCK, 'stale expected hash for the routing block');

// 2. A faithful deployment, built from the repository, with canary secrets.
$root = sys_get_temp_dir() . '/mm_diag_' . bin2hex(random_bytes(4));
$put = static function (string $path, string $content) use ($root): void {
    @mkdir(dirname($root . '/' . $path), 0777, true);
    file_put_contents($root . '/' . $path, $content);
};
foreach (MM_DIAG_EXPECTED as $deployed => $sha) {
    $put(str_replace('{profile}', 'Witosa', $deployed), (string) file_get_contents($inRepo($deployed)));
}
$put('mobileapi-core/active-profile.php', "<?php\nreturn 'Witosa';\n");
$put('public_html/.htaccess', "RewriteEngine On\n# BEGIN MINISTRANT MANAGER MOBILEAPI\n" . $snippet . "\n# END MINISTRANT MANAGER MOBILEAPI\n\nSetEnv CANARY_HTACCESS_SECRET s3cr3t-htaccess\n");
$CANARIES = ['CANARY-DB-PASSWORD-7731', 'CANARY-INTERNAL-API-SECRET-4410', 's3cr3t-htaccess', 'CANARY-TOKEN-ABC', 'CANARY-INSTALLATION-ID', 'CANARY-USER-ID-99', 'CANARY-TICKET-VALUE'];
$put('public_html/config/database.php', "<?php\n\$p = '" . $CANARIES[0] . "';\n");
$put('public_html/config/mobile_internal_api_secret.php', "<?php\ndefine('MOBILE_INTERNAL_API_SECRET', '" . $CANARIES[1] . "');\n");

$report = mm_diag_collect($root, MM_DIAG_EXPECTED, 1760000000);
$json = json_encode($report, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);

foreach ($report['files'] as $f) {
    $check($f['present'] && $f['matches_repository'] === true, 'a faithful deployment must match: ' . $f['path']);
}
$check($report['active_profile']['profile'] === 'Witosa' && $report['active_profile']['handoff_endpoint_present'], 'active profile not read');
$check($report['registry']['readable'] && $report['registry']['entries'] > 20, 'registry not read');
$check($report['registry']['entry_page_present'] && $report['registry']['entry_page_hidden'], 'entry page must be allowlisted and hidden');
$check($report['routing']['block_present'] && $report['routing']['block_matches_installer'] === true && $report['routing']['handoff_rule_present'], 'routing block not recognised');
$check($report['config_files_present'] === ['mobile_internal_api_secret.php' => true, 'database.php' => true], 'config presence');

// 3. Drift is DETECTED, one file at a time.
$put('mobileapi-core/ParishAdapters/Witosa/modules_builder.php', "<?php\n// an older registry without the entry page\nreturn ['x' => ['path' => '/public/justifications.php']];\n");
$drift = mm_diag_collect($root, MM_DIAG_EXPECTED, 1760000000);
$byPath = array_column($drift['files'], null, 'path');
$check($byPath['mobileapi-core/ParishAdapters/Witosa/modules_builder.php']['matches_repository'] === false, 'changed registry file must not match');
$check($byPath['mobileapi-core/ParishAdapters/Witosa/webview_handoff.php']['matches_repository'] === true, 'untouched file must still match');
$check($drift['registry']['entry_page_present'] === false, 'a registry without the entry page must be reported as such');

// 4. Missing pieces are reported, not fatal.
unlink($root . '/mobileapi-core/active-profile.php');
$bare = mm_diag_collect($root, MM_DIAG_EXPECTED, 1760000000);
$check($bare['active_profile']['file_present'] === false && $bare['active_profile']['profile'] === null, 'missing profile file');

// 5. The database part: a hostile table full of sensitive columns.
$rows = [];
$query = static function (string $sql) use (&$rows, $CANARIES): array {
    if (str_starts_with($sql, 'SHOW TABLES')) return [['t' => 'webview_handoff_tickets']];
    if (str_starts_with($sql, 'SELECT COUNT(*) FROM')) return [['n' => 5]];
    if (str_contains($sql, 'GROUP BY target_path')) {
        return [['target_path' => '/public/dashboard.php', 'c' => 4], ['target_path' => "/x\n<script>" . $CANARIES[3], 'c' => 1]];
    }
    // Rows as a careless query might return them: with the ticket value,
    // the user and the installation id alongside the safe columns.
    return [[
        'id' => 7, 'target_path' => '/public/dashboard.php', 'created_at' => '2026-10-08 10:00:00',
        'expires_at' => '2026-10-08 10:01:00', 'used_at' => null,
        'ticket' => $CANARIES[6], 'user_id' => $CANARIES[5], 'installation_id' => $CANARIES[4], 'token' => $CANARIES[3],
    ]];
};
$db = mm_diag_database($query);
$dbJson = json_encode($db, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
$check($db['table_present'] === true && $db['recent'][0]['target_path'] === '/public/dashboard.php', 'ticket metadata');
$check(array_keys($db['recent'][0]) === ['id', 'target_path', 'created_at', 'expires_at', 'used_at'], 'ticket rows must carry exactly the whitelisted columns');
$check(isset($db['by_target_path_last_7d']['[withheld: unexpected shape]']), 'a path with an unexpected shape must be withheld');
$noTable = mm_diag_database(static fn (string $sql): array => []);
$check($noTable['table_present'] === false, 'missing tickets table');

// 6. NOTHING sensitive appears anywhere in any output.
foreach ([$json, json_encode($drift), json_encode($bare), $dbJson] as $out) {
    foreach ($CANARIES as $canary) {
        $check(!str_contains((string) $out, $canary), "a secret leaked into the output: $canary");
    }
}

// 7. The script must not depend on mysqlnd (the package's own rule).
$check(!str_contains((string) file_get_contents(__DIR__ . '/../scripts/diagnose_handoff.php'), 'fetch_all('), 'mysqlnd-dependent fetch_all');

// cleanup
$rm = static function (string $dir) use (&$rm): void {
    foreach (scandir($dir) ?: [] as $e) {
        if ($e === '.' || $e === '..') continue;
        $p = $dir . '/' . $e;
        is_dir($p) ? $rm($p) : unlink($p);
    }
    rmdir($dir);
};
$rm($root);

if ($failures !== []) {
    fwrite(STDERR, "diagnose_handoff_test FAILED:\n - " . implode("\n - ", $failures) . "\n");
    exit(1);
}
echo "diagnose_handoff_test OK\n";
