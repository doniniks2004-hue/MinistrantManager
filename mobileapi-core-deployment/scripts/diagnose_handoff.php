<?php
declare(strict_types=1);

/**
 * Ministrant Manager - READ-ONLY diagnostics of a deployed MobileAPI handoff.
 *
 * Answers, without touching anything: are the files that serve
 * POST /api/v1/mobile/webview/handoff the ones in the repository, which
 * adapter is active, which pages does the deployed registry allow, is the
 * routing rule installed, and (optionally) which paths were tickets issued
 * for and were they used.
 *
 * Run from /home/<user>/ next to public_html/ and mobileapi-core/:
 *   php diagnose_handoff.php            files, profile, registry, routing
 *   php diagnose_handoff.php --with-db  + ticket metadata (second JSON object)
 *   php diagnose_handoff.php --root=/home/<user>
 *
 * It NEVER prints: tokens, tickets, installation ids, user ids, e-mail
 * addresses, database credentials, or the contents of any configuration or
 * secret file (only whether one exists). Output is built from a fixed
 * whitelist of fields; nothing is passed through from a file or a table.
 * It does not execute any deployed PHP: files are hashed and read as text.
 * CLI only.
 */

// Expected sha256 of each file as it is in the repository at the commit that
// added this script. tests/diagnose_handoff_test.php fails if a file changes
// without these being updated, so they cannot silently go stale.
// deployed path (relative to the account root) => sha256
const MM_DIAG_EXPECTED = [
    'public_html/mm-mobile-webview-handoff.php' => '84688e32d8dbaef90fe5935fc05504c7eeaa44d97639347e5b153173b618ca2b',
    'public_html/public/mobile_handoff.php' => 'f5614ad6fe51866b3161a092a7fdffd3f7b3f3a0b8d0db70bce7de42b878c181',
    'mobileapi-core/ParishAdapters/dispatch.php' => 'cb3950f1042ed8c86cdb31f53f64b67c717c327f72098c64afcb89caa6257802',
    'mobileapi-core/ParishAdapters/{profile}/webview_handoff.php' => 'eb35983bbb4e1759419c0d899115858a229aafe823ed291e4de60205eca88ae6',
    'mobileapi-core/ParishAdapters/{profile}/wiring.php' => '6e151bdc018fddf33fbc4dc96cf4ec81b28f63a30b86ff9653c0808701d1c987',
    'mobileapi-core/ParishAdapters/{profile}/modules_builder.php' => 'a72a34f863e37e919e85c7b23fac41c0381275a472ab446d3387f8780f65a77e',
    'mobileapi-core/Auth/WebviewHandoffTicketService.php' => '37b01a7f96771246a97a1902ae28f514c2e44ae5a43586a7f4d7903263fa354c',
    // Present in the package but NOT routed by the current .htaccess snippet.
    'public_html/api/mobile/webview_handoff.php' => 'cde181fd0a728781b4b7efbe9e0fdfd66c053035ef0ac29e5e6370aac273b571',
];

// sha256 of the routing block (trimmed) that the installer writes.
const MM_DIAG_ROUTING_BLOCK = 'ecfa646c76e0f2c328751f69bec2858c81dd9317ce5546a413b6929f20f974be';

const MM_DIAG_ENTRY_PAGE = '/public/dashboard.php';

function mm_diag_iso(int $ts): string
{
    return gmdate('Y-m-d\TH:i:s\Z', $ts);
}

/** A path shown in the output must look like a path; anything else is withheld. */
function mm_diag_safe_path(mixed $value): string
{
    return is_string($value) && preg_match('#^/[A-Za-z0-9_./-]{1,100}$#', $value) === 1
        ? $value
        : '[withheld: unexpected shape]';
}

function mm_diag_read_profile(string $root): array
{
    $file = $root . '/mobileapi-core/active-profile.php';
    $out = ['file_present' => is_file($file), 'profile' => null, 'adapter_dir_present' => false, 'handoff_endpoint_present' => false];
    if (!$out['file_present']) return $out;
    // Parsed as text, never executed.
    if (preg_match('/return\s+[\'"]([A-Za-z0-9_-]{1,40})[\'"]\s*;/', (string) file_get_contents($file), $m) === 1) {
        $out['profile'] = $m[1];
        $dir = $root . '/mobileapi-core/ParishAdapters/' . $m[1];
        $out['adapter_dir_present'] = is_dir($dir);
        $out['handoff_endpoint_present'] = is_file($dir . '/webview_handoff.php');
    }
    return $out;
}

function mm_diag_registry(string $root, ?string $profile): array
{
    $out = ['readable' => false, 'entries' => 0, 'entry_page_present' => false, 'entry_page_hidden' => false, 'paths' => []];
    if ($profile === null) return $out;
    $file = $root . '/mobileapi-core/ParishAdapters/' . $profile . '/modules_builder.php';
    if (!is_file($file)) return $out;
    $src = (string) file_get_contents($file);
    preg_match_all("#'path'\\s*=>\\s*'(/public/[A-Za-z0-9_./-]+)'#", $src, $m);
    $paths = array_values(array_unique($m[1]));
    sort($paths);
    $out['readable'] = true;
    $out['entries'] = count($paths);
    $out['entry_page_present'] = in_array(MM_DIAG_ENTRY_PAGE, $paths, true);
    $out['entry_page_hidden'] = preg_match("#'dashboard'\\s*=>\\s*\\[[^\\]]*'hidden'\\s*=>\\s*true#s", $src) === 1;
    $out['paths'] = array_map('mm_diag_safe_path', $paths);
    return $out;
}

function mm_diag_routing(string $root): array
{
    $file = $root . '/public_html/.htaccess';
    $out = ['htaccess_present' => is_file($file), 'block_present' => false, 'block_matches_installer' => null, 'handoff_rule_present' => false];
    if (!$out['htaccess_present']) return $out;
    $text = (string) file_get_contents($file);
    if (preg_match('/# BEGIN MINISTRANT MANAGER MOBILEAPI\n(.*?)\n# END MINISTRANT MANAGER MOBILEAPI/s', $text, $m) === 1) {
        $out['block_present'] = true;
        $out['block_matches_installer'] = hash('sha256', trim($m[1])) === MM_DIAG_ROUTING_BLOCK;
        $out['handoff_rule_present'] = str_contains($m[1], 'RewriteRule ^api/v1/mobile/webview/handoff/?$ mm-mobile-webview-handoff.php [END,QSA]');
    }
    return $out;
}

/** @param array<string,string> $expected */
function mm_diag_collect(string $root, array $expected, ?int $now = null): array
{
    $root = rtrim($root, '/');
    $profile = mm_diag_read_profile($root);
    $files = [];
    foreach ($expected as $deployed => $sha) {
        $relative = $profile['profile'] !== null ? str_replace('{profile}', $profile['profile'], $deployed) : $deployed;
        $path = $root . '/' . $relative;
        $entry = ['path' => $relative, 'present' => is_file($path), 'sha256' => null, 'matches_repository' => null, 'size' => null, 'modified_utc' => null];
        if ($entry['present']) {
            $entry['sha256'] = hash_file('sha256', $path);
            $entry['matches_repository'] = hash_equals($sha, $entry['sha256']);
            $entry['size'] = (int) filesize($path);
            $entry['modified_utc'] = mm_diag_iso((int) filemtime($path));
        }
        $files[] = $entry;
    }
    return [
        'generated_at_utc' => mm_diag_iso($now ?? time()),
        'php_version' => PHP_VERSION,
        'files' => $files,
        'active_profile' => $profile,
        'registry' => mm_diag_registry($root, $profile['profile']),
        'routing' => mm_diag_routing($root),
        // Existence only. Never the contents.
        'config_files_present' => [
            'mobile_internal_api_secret.php' => is_file($root . '/public_html/config/mobile_internal_api_secret.php'),
            'database.php' => is_file($root . '/public_html/config/database.php'),
        ],
    ];
}

/**
 * Only these five columns, whatever the row contains. The ticket value, the
 * user id and the installation id are never read into the output.
 */
function mm_diag_ticket_row(array $row): array
{
    return [
        'id' => (int) ($row['id'] ?? 0),
        'target_path' => mm_diag_safe_path($row['target_path'] ?? null),
        'created_at' => is_string($row['created_at'] ?? null) ? $row['created_at'] : null,
        'expires_at' => is_string($row['expires_at'] ?? null) ? $row['expires_at'] : null,
        'used_at' => is_string($row['used_at'] ?? null) ? $row['used_at'] : null,
    ];
}

/** @param callable(string):array $query returns rows for a fixed, parameterless SELECT */
function mm_diag_database(callable $query): array
{
    $out = ['connected' => true, 'table_present' => false];
    $exists = $query("SHOW TABLES LIKE 'webview_handoff_tickets'");
    if ($exists === []) return $out;
    $out['table_present'] = true;
    $one = static fn (string $sql): int => (int) (array_values(($query($sql)[0] ?? [0]))[0] ?? 0);
    $out['tickets_total'] = $one('SELECT COUNT(*) FROM webview_handoff_tickets');
    $out['created_last_24h'] = $one('SELECT COUNT(*) FROM webview_handoff_tickets WHERE created_at >= NOW() - INTERVAL 1 DAY');
    $out['used_last_24h'] = $one('SELECT COUNT(*) FROM webview_handoff_tickets WHERE used_at IS NOT NULL AND created_at >= NOW() - INTERVAL 1 DAY');
    $out['expired_unused_last_24h'] = $one('SELECT COUNT(*) FROM webview_handoff_tickets WHERE used_at IS NULL AND expires_at < NOW() AND created_at >= NOW() - INTERVAL 1 DAY');
    $byPath = [];
    foreach ($query('SELECT target_path, COUNT(*) AS c FROM webview_handoff_tickets WHERE created_at >= NOW() - INTERVAL 7 DAY GROUP BY target_path ORDER BY c DESC LIMIT 20') as $row) {
        $byPath[mm_diag_safe_path($row['target_path'] ?? null)] = (int) ($row['c'] ?? 0);
    }
    $out['by_target_path_last_7d'] = $byPath;
    $out['recent'] = array_map('mm_diag_ticket_row', $query('SELECT id, target_path, created_at, expires_at, used_at FROM webview_handoff_tickets ORDER BY id DESC LIMIT 15'));
    return $out;
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    $root = getcwd() ?: '.';
    $withDb = false;
    foreach (array_slice($argv, 1) as $arg) {
        if ($arg === '--with-db') $withDb = true;
        elseif (str_starts_with($arg, '--root=')) $root = substr($arg, 7);
    }
    if (!is_dir($root . '/mobileapi-core') || !is_dir($root . '/public_html')) {
        fwrite(STDERR, "ERROR: run next to mobileapi-core/ and public_html/ (or pass --root=...).\n");
        exit(1);
    }
    echo json_encode(mm_diag_collect($root, MM_DIAG_EXPECTED), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";

    if ($withDb) {
        // Printed AFTER the part above: the application's own database.php
        // may exit on error, and the first part must already be out.
        ob_start();
        $conn = null;
        (static function () use ($root, &$conn): void { include $root . '/public_html/config/database.php'; })();
        ob_end_clean();
        if (!isset($conn) || !($conn instanceof mysqli)) {
            echo json_encode(['database' => ['connected' => false]]), "\n";
            exit(0);
        }
        $query = static function (string $sql) use ($conn): array {
            $result = $conn->query($sql);
            // fetch_assoc loop, not fetch_all: the package must not depend on mysqlnd.
            $rows = [];
            if ($result instanceof mysqli_result) {
                while ($row = $result->fetch_assoc()) {
                    $rows[] = $row;
                }
            }
            return $rows;
        };
        echo json_encode(['database' => mm_diag_database($query)], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
    }
}
