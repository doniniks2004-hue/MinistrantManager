<?php
/**
 * Uruchom RAZ, na prawdziwym serwerze Witosy, przez SSH/CLI (nigdy przez
 * HTTP, nigdy z poziomu przeglądarki):
 *
 *   php create_test_account.php
 *
 * Tworzy jedno konto testowe do smoke-testów mobilnych + 3 wpisy w
 * grafiku (2 przeszłe/bieżące + 1 przyszły, do ręcznej zmiany w panelu
 * WWW na potrzeby testu z punktu 6 milestone'u). Hasło jest losowane
 * przy KAŻDYM uruchomieniu i wypisywane WYŁĄCZNIE na ekran — nigdzie nie
 * jest zapisywane (ani do repo, ani do logów, ani do żadnego pliku).
 * Zapisz je od razu po uruchomieniu — nie da się go odtworzyć później
 * (w bazie jest tylko hash).
 *
 * Bezpieczne do wielokrotnego uruchomienia: jeśli username już istnieje,
 * aktualizuje tylko hasło (nowe, znów tylko na ekranie) i nie tworzy
 * duplikatu ani nie dotyka istniejących wpisów grafiku.
 */

require __DIR__ . '/public_html/config/database.php';
// ⚠ Ten skrypt zakłada, że leży BEZPOŚREDNIO w tym samym katalogu co
// mobileapi-core/ i public_html/ (czyli: /home/<user>/create_test_account.php,
// /home/<user>/public_html/) — skopiuj go tam z scripts/ przed
// uruchomieniem. Potrzebny jest tylko $conn (mysqli), tak jak w każdym
// innym miejscu tego pakietu.

const TEST_USERNAME = 'mobile_test_witosa';
const TEST_FULL_NAME = 'Test Mobile (Witosa)';
const TEST_ROLE_ID = 5; // Ministrant — dopasuj do realnego id roli na Witosie, jeśli inne

// Review round fix (cleanup): jednoznaczny, nie-zgadywalny marker na
// początku KAŻDEGO opisu wydarzenia utworzonego przez ten skrypt —
// cleanup_test_account.php znajduje po nim WYŁĄCZNIE te 3 wydarzenia po
// treści, nigdy po zgadywaniu ID (auto_increment mógł się przesunąć,
// gdyby ktoś ręcznie coś dodał/usunął między create a cleanup).
const TEST_MARKER = '[MOBILE_TEST_WITOSA]';

function randomPassword(int $length = 16): string
{
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%';
    $password = '';
    for ($i = 0; $i < $length; $i++) {
        $password .= $alphabet[random_int(0, strlen($alphabet) - 1)];
    }
    return $password;
}

$password = randomPassword();
$hash = password_hash($password, PASSWORD_BCRYPT);

$stmt = $conn->prepare('SELECT id FROM users WHERE username = ?');
$username = TEST_USERNAME;
$stmt->bind_param('s', $username);
$stmt->execute();
$existing = $stmt->get_result()->fetch_assoc();
$stmt->close();

if ($existing) {
    $userId = (int) $existing['id'];
    $stmt = $conn->prepare('UPDATE users SET password = ? WHERE id = ?');
    $stmt->bind_param('si', $hash, $userId);
    $stmt->execute();
    $stmt->close();
    echo "Konto już istniało (id=$userId) — zaktualizowano TYLKO hasło.\n";
} else {
    $stmt = $conn->prepare(
        'INSERT INTO users (username, password, full_name, role_id, is_active, can_request_substitution, can_accept_substitution)
         VALUES (?, ?, ?, ?, 1, 1, 1)'
    );
    $roleId = TEST_ROLE_ID;
    $fullName = TEST_FULL_NAME;
    $stmt->bind_param('sssi', $username, $hash, $fullName, $roleId);
    $stmt->execute();
    $userId = $conn->insert_id;
    $stmt->close();
    echo "Utworzono nowe konto testowe (id=$userId).\n";

    // Trzy wpisy w grafiku — DWA w realnym oknie bootstrapu (-7/+90 dni
    // od dziś), JEDEN wyraźnie w przyszłości (poza tym oknem), specjalnie
    // do ręcznej zmiany w panelu WWW na potrzeby testu "webowy grafik ==
    // bootstrap API" (milestone punkt 6) — dopiero gdy zbliży się do
    // okna -7/+90, pojawi się też w /mobile/bootstrap, co jest częścią
    // tego, co ten test ma sprawdzić.
    $inTwoWeeks = date('Y-m-d H:i:s', strtotime('+14 days 10:00'));
    $inFiveWeeks = date('Y-m-d H:i:s', strtotime('+35 days 10:00'));
    $farFuture = date('Y-m-d H:i:s', strtotime('+200 days 10:00'));

    $stmt = $conn->prepare('INSERT INTO events (module_id, event_date, description) VALUES (1, ?, ?)');
    $desc1 = TEST_MARKER . ' Msza testowa (mobile smoke test) #1';
    $stmt->bind_param('ss', $inTwoWeeks, $desc1);
    $stmt->execute();
    $eventId1 = $conn->insert_id;
    $desc2 = TEST_MARKER . ' Msza testowa (mobile smoke test) #2';
    $stmt->bind_param('ss', $inFiveWeeks, $desc2);
    $stmt->execute();
    $eventId2 = $conn->insert_id;
    $desc3 = TEST_MARKER . ' Msza testowa (mobile smoke test) #3 — DALEKA PRZYSZŁOŚĆ, do zmiany w panelu WWW dla testu z punktu 6';
    $stmt->bind_param('ss', $farFuture, $desc3);
    $stmt->execute();
    $eventId3 = $conn->insert_id;
    $stmt->close();

    $stmt = $conn->prepare('INSERT INTO schedule (event_id, user_id, role_id, is_present, status) VALUES (?, ?, 1, 0, \'assigned\')');
    foreach ([$eventId1, $eventId2, $eventId3] as $eid) {
        $stmt->bind_param('ii', $eid, $userId);
        $stmt->execute();
    }
    $stmt->close();

    echo "Dodano 3 wpisy w grafiku (events id: $eventId1, $eventId2, $eventId3).\n";
    echo "Wpis #3 (id=$eventId3, data: $farFuture) jest CELOWO daleko w przyszłości —\n";
    echo "to ten do ręcznej zmiany w panelu WWW na potrzeby testu z punktu 6.\n";
}

echo "\n=========================================\n";
echo "DANE TESTOWE (zapisz teraz — nie da się odtworzyć hasła później):\n";
echo "  username: " . TEST_USERNAME . "\n";
echo "  password: $password\n";
echo "  user_id:  $userId\n";
echo "=========================================\n";
echo "Nie commituj tych danych do repo/GitHub.\n";
