<?php
/**
 * Uruchom RAZ, po zakończeniu smoke-testów i ręcznej weryfikacji z
 * punktu 6 (web vs /bootstrap), przez SSH/CLI:
 *
 *   php cleanup_test_account.php
 *
 * Usuwa WYŁĄCZNIE to, co utworzył `create_test_account.php`:
 *   - 3 wydarzenia oznaczone markerem `[MOBILE_TEST_WITOSA]` w opisie
 *     (nigdy po zgadywaniu ID — auto_increment mógł się przesunąć)
 *   - odpowiadające im wpisy `schedule`
 *   - wszystkie `mobile_user_tokens` konta testowego (niezależnie od
 *     tego, ile razy/z ilu installation_id logowano się nim podczas
 *     testów)
 *   - samo konto `mobile_test_witosa`
 *
 * Nie dotyka NICZEGO innego. Bezpieczne i idempotentne — drugie
 * uruchomienie po pierwszym sprzątnięciu po prostu nic nie znajduje i
 * kończy się bez błędu.
 *
 * ⚠ Jeśli podczas testu z punktu 6 (web vs /bootstrap) edytowałeś/aś
 * treść OPISU wydarzenia #3 w panelu WWW: zostaw prefiks
 * `[MOBILE_TEST_WITOSA]` na początku opisu (zmień resztę tekstu/datę
 * dowolnie) — inaczej ten jeden rekord nie zostanie znaleziony przez
 * cleanup i trzeba go będzie usunąć ręcznie.
 */

require __DIR__ . '/public_html/config/database.php';
// ⚠ Ten skrypt zakłada, że leży BEZPOŚREDNIO w tym samym katalogu co
// mobileapi-core/ i public_html/ — tak samo jak create_test_account.php.

const TEST_USERNAME = 'mobile_test_witosa';
const TEST_MARKER = '[MOBILE_TEST_WITOSA]';

echo "=== Sprzątanie danych testowych (" . TEST_USERNAME . ") ===\n\n";

// 1. Znajdź konto testowe (po username — jeśli go nie ma, cały cleanup
// jest no-opem, co jest poprawnym zachowaniem przy drugim uruchomieniu).
$stmt = $conn->prepare('SELECT id FROM users WHERE username = ?');
$username = TEST_USERNAME;
$stmt->bind_param('s', $username);
$stmt->execute();
$user = $stmt->get_result()->fetch_assoc();
$stmt->close();

if ($user === null) {
    echo "Konto '$username' nie istnieje — nic do sprzątnięcia (albo już posprzątane wcześniej).\n";
    exit(0);
}
$userId = (int) $user['id'];
echo "Znaleziono konto testowe: id=$userId\n";

// 2. Znajdź wydarzenia PO MARKERZE w opisie — nigdy po zgadywaniu ID.
$marker = TEST_MARKER . '%';
$stmt = $conn->prepare('SELECT id FROM events WHERE description LIKE ?');
$stmt->bind_param('s', $marker);
$stmt->execute();
$eventIds = array_map(fn($r) => (int) $r['id'], $stmt->get_result()->fetch_all(MYSQLI_ASSOC));
$stmt->close();
echo 'Znaleziono ' . count($eventIds) . " oznaczonych wydarzeń testowych: " . implode(', ', $eventIds) . "\n";

if (!empty($eventIds)) {
    $placeholders = implode(',', array_fill(0, count($eventIds), '?'));
    $types = str_repeat('i', count($eventIds));

    // 2a. Wpisy schedule odwołujące się do tych wydarzeń.
    $stmt = $conn->prepare("DELETE FROM schedule WHERE event_id IN ($placeholders)");
    $stmt->bind_param($types, ...$eventIds);
    $stmt->execute();
    $deletedSchedule = $stmt->affected_rows;
    $stmt->close();
    echo "Usunięto $deletedSchedule wpisów schedule.\n";

    // 2b. Same wydarzenia.
    $stmt = $conn->prepare("DELETE FROM events WHERE id IN ($placeholders)");
    $stmt->bind_param($types, ...$eventIds);
    $stmt->execute();
    $deletedEvents = $stmt->affected_rows;
    $stmt->close();
    echo "Usunięto $deletedEvents wydarzeń testowych.\n";
} else {
    echo "Brak oznaczonych wydarzeń do usunięcia (może już posprzątane, albo edytowano opis bez zachowania markera — patrz docblock tego pliku).\n";
}

// 3. Wszystkie mobile_user_tokens tego konta (niezależnie od installation_id).
$stmt = $conn->prepare('DELETE FROM mobile_user_tokens WHERE user_id = ?');
$stmt->bind_param('i', $userId);
$stmt->execute();
$deletedTokens = $stmt->affected_rows;
$stmt->close();
echo "Usunięto $deletedTokens tokenów mobile_user_tokens.\n";

// 4. Samo konto.
$stmt = $conn->prepare('DELETE FROM users WHERE id = ?');
$stmt->bind_param('i', $userId);
$stmt->execute();
$stmt->close();
echo "Usunięto konto testowe (id=$userId).\n";

echo "\n=== Sprzątanie zakończone. ===\n";
