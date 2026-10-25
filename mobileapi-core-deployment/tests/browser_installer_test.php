<?php
declare(strict_types=1);
function check(bool $condition, string $message): void { if (!$condition) throw new RuntimeException($message); }
function copyPackage(string $source, string $target): void {
    mkdir($target, 0700, true);
    foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($source, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::SELF_FIRST) as $item) {
        $dest = $target . '/' . substr($item->getPathname(), strlen($source) + 1);
        if ($item->isDir()) mkdir($dest, 0700, true); else copy($item->getPathname(), $dest);
    }
}
$root = sys_get_temp_dir() . '/mm-browser-' . bin2hex(random_bytes(8));
mkdir($root . '/public_html/config', 0700, true);
copyPackage(dirname(__DIR__), $root . '/mm-installer');
copy($root . '/mm-installer/browser/mm-setup.php', $root . '/public_html/mm-setup.php');
$key = bin2hex(random_bytes(32));
$secret = bin2hex(random_bytes(32));
file_put_contents($root . '/mm-installer/browser/access.php', '<?php return ' . var_export(['access_key' => $key], true) . ';');
file_put_contents($root . '/public_html/config/database.php', "<?php\n\$conn = new mysqli('127.0.0.1', 'root', '', 'ministrant_browser_test', 3306);\n");
$db = new mysqli('127.0.0.1', 'root', '', '', 3306);
$db->query('CREATE DATABASE ministrant_browser_test');
$db->select_db('ministrant_browser_test');
foreach (['users','events','schedule','announcements'] as $table) $db->query("CREATE TABLE $table (id INT NOT NULL PRIMARY KEY) ENGINE=InnoDB");
$socket = stream_socket_server('tcp://127.0.0.1:0', $errno, $error);
$address = stream_socket_get_name($socket, false); fclose($socket);
$process = proc_open([PHP_BINARY, '-d', 'disable_functions=exec,passthru,shell_exec,system,proc_open', '-S', $address, '-t', $root . '/public_html'], [0=>['pipe','r'], 1=>['file',$root.'/server.log','a'], 2=>['file',$root.'/server.log','a']], $pipes, null, array_merge(getenv(), ['MM_INSTALLER_TEST_HTTP'=>'1']));
$cookie = '';
function request(string $path, ?array $post = null): array {
    global $address, $cookie;
    $headers = 'Cookie: ' . $cookie . "\r\n";
    if ($post !== null) $headers .= "Content-Type: application/x-www-form-urlencoded\r\n";
    $context = stream_context_create(['http'=>['method'=>$post === null ? 'GET' : 'POST','header'=>$headers,'content'=>$post === null ? '' : http_build_query($post),'ignore_errors'=>true,'timeout'=>30]]);
    $body = file_get_contents('http://' . $address . $path, false, $context);
    foreach ($http_response_header as $header) if (preg_match('/^Set-Cookie: (MM_BROWSER_SETUP=[^;]+)/i', $header, $m)) $cookie = $m[1];
    preg_match('/\s(\d{3})\s/', $http_response_header[0], $m);
    return [(int)$m[1], (string)$body];
}
function csrf(string $body): string { preg_match('/name="csrf" value="([a-f0-9]+)"/', $body, $m); return $m[1] ?? ''; }
try {
    for ($n=0; $n<50; $n++) { $ready = @fsockopen(explode(':',$address)[0], (int)explode(':',$address)[1]); if ($ready) { fclose($ready); break; } usleep(100000); }
    [$status,$body] = request('/mm-setup.php'); check($status===200, 'GET login failed'); $token=csrf($body);
    [$status] = request('/mm-setup.php', ['action'=>'install','csrf'=>$token,'backup_confirmed'=>'yes']); check($status===403, 'Anonymous install allowed');
    [$status] = request('/mm-setup.php', ['action'=>'login','access_key'=>$key,'csrf'=>'bad']); check($status===403, 'CSRF bypass');
    [$status] = request('/mm-setup.php', ['action'=>'login','access_key'=>'wrong','csrf'=>$token]); check($status===403, 'Wrong key accepted');
    [$status,$body] = request('/mm-setup.php', ['action'=>'login','access_key'=>$key,'csrf'=>$token]); check($status===200, 'Login failed'); $token=csrf($body);
    [$status] = request('/mm-setup.php', ['action'=>'install','csrf'=>$token,'backup_confirmed'=>'yes']); check($status===409, 'Install without check allowed');
    [$status,$body] = request('/mm-setup.php', ['action'=>'check','csrf'=>$token]); check($status===200 && str_contains($body,'DRY RUN OK'), 'Check failed: '.$body);
    check($db->query("SHOW TABLES LIKE 'mobile_meta'")->num_rows===0, 'Check mutated schema');
    [$status] = request('/mm-setup.php', ['action'=>'install','csrf'=>$token]); check($status===409, 'Backup confirmation bypass');
    file_put_contents($root.'/public_html/mm-mobile-session-login.php', 'old endpoint');
    $badMigration = $root.'/mm-installer/migrations/999_test_failure.sql';
    file_put_contents($badMigration, 'INVALID SQL FOR TEST');
    [$status,$body] = request('/mm-setup.php', ['action'=>'install','csrf'=>$token,'backup_confirmed'=>'yes','parish_secret'=>$secret]);
    check($status===500 && !str_contains($body,'MOBILEAPI INSTALL OK'), 'Failed migration reported success');
    check(file_get_contents($root.'/public_html/mm-mobile-session-login.php')==='old endpoint', 'Failure did not restore old endpoint');
    check(!is_file($root.'/public_html/config/mobile_internal_api_secret.php'), 'Failure left newly written secret');
    check(!is_file($root.'/mm-installer/browser/completed.lock'), 'Failure locked out retry');
    check(!str_contains($body,$secret), 'Failure exposed secret');
    unlink($badMigration);
    [$status,$body] = request('/mm-setup.php', ['action'=>'check','csrf'=>$token]); check($status===200, 'Recheck after failure denied');
    [$status,$body] = request('/mm-setup.php', ['action'=>'install','csrf'=>$token,'backup_confirmed'=>'yes','parish_secret'=>$secret]);
    check($status===200 && str_contains($body,'MOBILEAPI INSTALL OK'), 'Browser installation failed: '.$body);
    check(!str_contains($body,$secret) && !str_contains($body,$key), 'Secret leaked');
    check($db->query('SELECT * FROM mobile_meta WHERE id=1')->num_rows===1, 'Metadata missing');
    check(is_file($root.'/public_html/mm-mobile-session-login.php'), 'Endpoint missing');
    check(is_file($root.'/mm-installer/browser/completed.lock'), 'Completion lock missing');
    [$status] = request('/mm-setup.php'); check($status===410, 'Completed installer still accessible');
    [$status] = request('/mm-setup.php', ['action'=>'install','csrf'=>$token,'backup_confirmed'=>'yes']); check($status===410, 'Repeat install allowed');
    unlink($root.'/mm-installer/browser/completed.lock');
    [$status,$body] = request('/mm-setup.php'); $token=csrf($body);
    for ($n=0; $n<5; $n++) {
        [$status] = request('/mm-setup.php', ['action'=>'login','access_key'=>'wrong','csrf'=>$token]);
        check($status===403, 'Unexpected rate-limit response');
    }
    [$status] = request('/mm-setup.php', ['action'=>'login','access_key'=>$key,'csrf'=>$token]); check($status===429, 'Rate limit bypassed');
    [$status] = request('/mm-installer/browser/access.php'); check($status===404, 'Private config publicly accessible');
    copy($root.'/mm-installer/install.php', $root.'/public_html/install.php');
    [$status] = request('/install.php'); check($status===403, 'Direct web access to CLI installer allowed');
    echo "BROWSER INSTALLER AUTH, CSRF, MYSQL INSTALL AND ONE-TIME LOCK OK (shell functions disabled)\n";
} finally {
    proc_terminate($process); proc_close($process);
    $db->query('DROP DATABASE ministrant_browser_test');
    foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST) as $item) { if ($item->isDir()) rmdir($item->getPathname()); else unlink($item->getPathname()); }
    rmdir($root);
}
