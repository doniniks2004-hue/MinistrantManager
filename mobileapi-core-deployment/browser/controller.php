<?php
declare(strict_types=1);
ini_set('display_errors', '0');
header('Cache-Control: no-store, private');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
header('Content-Type: text/html; charset=utf-8');
$secure = isset($_SERVER['HTTPS']) && strtolower((string) $_SERVER['HTTPS']) !== 'off';
$testHttp = PHP_SAPI === 'cli-server' && getenv('MM_INSTALLER_TEST_HTTP') === '1';
if (!$secure && !$testHttp) { http_response_code(403); exit('Otwórz instalator przez HTTPS.'); }
$targetRoot = dirname(__DIR__, 2);
if (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') !== realpath($targetRoot . '/public_html/mm-setup.php')) {
    http_response_code(404); exit('Umieść wyłącznie mm-setup.php w public_html, a paczkę w mm-installer obok public_html.');
}
$completed = __DIR__ . '/completed.lock';
if (file_exists($completed)) { http_response_code(410); exit('Instalator zablokowany po zakończeniu. Usuń public_html/mm-setup.php.'); }
if (!is_file(__DIR__ . '/access.php')) { http_response_code(503); exit('Najpierw skonfiguruj mm-installer/browser/access.php poza public_html.'); }
$config = require __DIR__ . '/access.php';
$key = is_array($config) ? ($config['access_key'] ?? '') : '';
if (!is_string($key) || strlen($key) < 32 || str_contains($key, 'REPLACE_')) {
    http_response_code(503); exit('Ustaw w access.php unikalny, losowy klucz instalatora (minimum 32 znaki).');
}
session_name('MM_BROWSER_SETUP');
session_start(['cookie_secure' => !$testHttp, 'cookie_httponly' => true, 'cookie_samesite' => 'Strict', 'use_strict_mode' => true, 'use_only_cookies' => true]);
$_SESSION['csrf'] ??= bin2hex(random_bytes(32));
function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
$action = $_POST['action'] ?? '';
$message = '';
$log = '';
$success = false;
$authenticated = ($_SESSION['auth_until'] ?? 0) >= time();
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!is_string($_POST['csrf'] ?? null) || !hash_equals($_SESSION['csrf'], $_POST['csrf'])) {
        http_response_code(403); exit('Nieprawidłowy token formularza. Odśwież stronę.');
    }
    if ($action === 'login') {
        $rate = fopen(__DIR__ . '/attempts.lock', 'c+');
        if ($rate === false || !flock($rate, LOCK_EX)) { http_response_code(503); exit('Nie można zabezpieczyć logowania.'); }
        $attempts = json_decode(stream_get_contents($rate), true) ?: [];
        $attempts = array_values(array_filter($attempts, static fn($t) => is_int($t) && $t > time() - 600));
        if (count($attempts) >= 5) { http_response_code(429); exit('Za dużo prób. Odczekaj 10 minut.'); }
        $given = $_POST['access_key'] ?? '';
        if (is_string($given) && hash_equals($key, $given)) {
            session_regenerate_id(true);
            $_SESSION['auth_until'] = time() + 1800;
            $_SESSION['csrf'] = bin2hex(random_bytes(32));
            $authenticated = true;
            $attempts = [];
        } else {
            $attempts[] = time(); http_response_code(403); $message = 'Nieprawidłowy klucz dostępu.';
        }
        rewind($rate); ftruncate($rate, 0); fwrite($rate, json_encode($attempts)); fflush($rate); fclose($rate);
    } elseif (!$authenticated) {
        http_response_code(403); $message = 'Zaloguj się ponownie.';
    } elseif (in_array($action, ['check', 'install'], true)) {
        if ($action === 'install' && (($_SESSION['checked_until'] ?? 0) < time() || ($_POST['backup_confirmed'] ?? '') !== 'yes')) {
            http_response_code(409); $message = 'Najpierw sprawdź profil i potwierdź kopię plików oraz bazy.';
        } else {
            $requestLock = fopen(__DIR__ . '/request.lock', 'c');
            if ($requestLock === false || !flock($requestLock, LOCK_EX | LOCK_NB)) { http_response_code(409); exit('Instalator już pracuje. Nie uruchamiaj kolejnej kopii.'); }
            // Check again after acquiring the lock: another request may have completed.
            if (file_exists($completed)) { http_response_code(410); exit('Instalacja została już zakończona.'); }
            $GLOBALS['mm_browser_secret'] = is_string($_POST['parish_secret'] ?? null) ? trim($_POST['parish_secret']) : '';
            define('MM_BROWSER_INSTALL', true);
            ob_start();
            try {
                if ($action === 'install') {
                    // Verify the one-time lock can be persisted BEFORE changing the parish.
                    $probe = __DIR__ . '/write-probe-' . bin2hex(random_bytes(8));
                    if (file_put_contents($probe, 'test', LOCK_EX) === false) throw new RuntimeException('Brak prawa zapisu w katalogu instalatora.');
                    unlink($probe);
                }
                (static function (string $targetRoot, string $action): void {
                    $argv = ['install.php', '--target=' . $targetRoot];
                    if ($action === 'check') $argv[] = '--dry-run';
                    require dirname(__DIR__) . '/install.php';
                })($targetRoot, $action);
                if ($action === 'check') {
                    $_SESSION['checked_until'] = time() + 900;
                    $message = 'Profil rozpoznany. To sprawdzenie struktury, nie test całej produkcji.';
                } else {
                    if (file_put_contents($completed, gmdate('c'), LOCK_EX) === false) throw new RuntimeException('Instalacja zakończona, ale nie zapisano blokady. NATYCHMIAST usuń mm-setup.php.');
                    $_SESSION = [];
                    session_destroy();
                    $success = true;
                    $message = 'MobileAPI zainstalowane. Usuń public_html/mm-setup.php i mm-installer/browser/access.php. Wykonaj test aktywacji i logowania.';
                }
            } catch (Throwable $e) {
                http_response_code(500);
                if (isset($GLOBALS['mm_restore_snapshot']) && !($GLOBALS['mm_install_complete'] ?? false)) {
                    try { ($GLOBALS['mm_restore_snapshot'])(); } catch (Throwable $rollbackError) {
                        $GLOBALS['mm_install_complete'] = true;
                        echo "\nAUTOMATYCZNE PRZYWRACANIE NIE POWIODŁO SIĘ. Użyj kopii plików i bazy.\n";
                    }
                }
                $message = 'Instalacja zatrzymana: ' . $e->getMessage();
                unset($_SESSION['checked_until']);
            } finally {
                $log = (string) ob_get_clean();
                foreach ([$key, $GLOBALS['mm_browser_secret']] as $sensitive) {
                    if ($sensitive !== '') { $message = str_replace($sensitive, '[ukryto]', $message); $log = str_replace($sensitive, '[ukryto]', $log); }
                }
                unset($GLOBALS['mm_browser_secret']);
                flock($requestLock, LOCK_UN); fclose($requestLock);
            }
        }
    } else { http_response_code(400); $message = 'Nieznana operacja.'; }
}
?>
<!doctype html><html lang="pl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Instalator MobileAPI</title>
<style>body{font:17px system-ui;max-width:760px;margin:32px auto;padding:0 20px;line-height:1.5;background:#f5f7fa;color:#172033}input[type=password]{display:block;width:95%;padding:12px;margin:8px 0 18px}button{padding:12px 20px;background:#184fc2;color:white;border:0;border-radius:6px;cursor:pointer}section,pre{background:white;padding:20px;border-radius:8px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px}label{display:block;margin:14px 0}</style>
<h1>Instalator MobileAPI</h1>
<?php if ($message !== ''): ?><section role="status"><?= h($message) ?></section><?php endif ?>
<?php if ($log !== ''): ?><pre><?= h($log) ?></pre><?php endif ?>
<?php if (!$success): ?>
<?php if (!$authenticated): ?>
<form method="post"><input type="hidden" name="csrf" value="<?= h($_SESSION['csrf']) ?>"><input type="hidden" name="action" value="login"><label>Osobny klucz instalatora<input type="password" name="access_key" required autocomplete="off"></label><button>Zaloguj się</button></form>
<?php else: ?>
<p>Instalacja dotyczy MobileAPI tej parafii. Wykonaj kopię plików i eksport bazy w panelu hostingu. Rollback plików nie cofa migracji bazy.</p>
<form method="post"><input type="hidden" name="csrf" value="<?= h($_SESSION['csrf']) ?>"><input type="hidden" name="action" value="check"><button>1. Sprawdź profil parafii</button></form>
<?php if (($_SESSION['checked_until'] ?? 0) >= time()): ?>
<form method="post"><input type="hidden" name="csrf" value="<?= h($_SESSION['csrf']) ?>"><input type="hidden" name="action" value="install"><label>Sekret MobileAPI parafii (zostaw puste, jeśli jest już skonfigurowany)<input type="password" name="parish_secret" autocomplete="off"></label><label><input type="checkbox" name="backup_confirmed" value="yes" required> Mam kopię plików i eksport bazy danych.</label><button>2. Zainstaluj MobileAPI</button></form>
<?php endif; endif; endif ?>
</html>
