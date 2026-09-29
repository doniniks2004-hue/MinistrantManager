<?php
/**
 * Uruchom PRZED migracjami, przez SSH/CLI:
 *
 *   php preflight.php
 *
 * Kończy z kodem 0 i "PREFLIGHT OK", jeśli bezpiecznie można kontynuować
 * do migracji. Kończy z kodem 1 i listą błędów, jeśli NIE — w takim
 * przypadku NIE uruchamiaj migracji, dopóki błędy nie zostaną
 * rozwiązane.
 *
 * Sprawdza:
 *   1. PHP >= 8.1 (readonly properties w DTO/DeviceContext.php,
 *      DTO/UserContext.php)
 *   2. rozszerzenie mysqli
 *   3. PASSWORD_ARGON2ID faktycznie działa (nie tylko że stała istnieje)
 *   4. jeśli mobile_user_tokens JUŻ istnieje — czy jej UNIQUE KEY jest
 *      poprawnie na samym installation_id, a NIE na starym
 *      (user_id, installation_id). `CREATE TABLE IF NOT EXISTS` w
 *      migracji 001 SAM TEGO NIE NAPRAWI, jeśli tabela już istnieje w
 *      złym kształcie.
 */

require __DIR__ . '/public_html/config/database.php';
// ⚠ Ten skrypt zakłada, że leży BEZPOŚREDNIO w tym samym katalogu co
// mobileapi-core/ i public_html/ — tak samo jak pozostałe skrypty w tym
// katalogu.

$errors = [];
$warnings = [];

echo "=== Preflight: sprawdzanie środowiska przed migracjami ===\n\n";

// 1. Wersja PHP.
if (version_compare(PHP_VERSION, '8.1.0', '<')) {
    $errors[] = 'PHP >= 8.1 wymagane (readonly properties w DTO/DeviceContext.php, DTO/UserContext.php) — znaleziono ' . PHP_VERSION;
} else {
    echo 'OK    PHP ' . PHP_VERSION . "\n";
}

// 2. Rozszerzenie mysqli.
if (!extension_loaded('mysqli')) {
    $errors[] = 'Rozszerzenie mysqli nie jest załadowane.';
} else {
    echo "OK    rozszerzenie mysqli załadowane\n";
}

// 3. Argon2id — nie tylko czy stała istnieje, ale czy faktycznie działa.
if (!defined('PASSWORD_ARGON2ID')) {
    $errors[] = 'Stała PASSWORD_ARGON2ID nie istnieje — PHP prawdopodobnie skompilowane bez libargon2.';
} else {
    $testHash = @password_hash('preflight-test', PASSWORD_ARGON2ID);
    if ($testHash === false || $testHash === null || !str_starts_with($testHash, '$argon2id$')) {
        $errors[] = 'PASSWORD_ARGON2ID istnieje, ale password_hash() z nim faktycznie się nie udało.';
    } else {
        echo "OK    PASSWORD_ARGON2ID działa (testowy hash: " . substr($testHash, 0, 20) . "...)\n";
    }
}

// 4. Kształt mobile_user_tokens, JEŚLI już istnieje.
$result = $conn->query("SHOW TABLES LIKE 'mobile_user_tokens'");
if ($result && $result->num_rows > 0) {
    echo "INFO  mobile_user_tokens już istnieje — sprawdzam kształt UNIQUE KEY...\n";
    $createResult = $conn->query('SHOW CREATE TABLE mobile_user_tokens');
    $row = $createResult->fetch_assoc();
    $createSql = $row['Create Table'];

    if (preg_match('/UNIQUE KEY `[^`]+` \(`installation_id`\)/', $createSql)) {
        echo "OK    UNIQUE poprawnie na samym installation_id\n";
    } elseif (preg_match('/UNIQUE KEY `[^`]+` \(`user_id`,`installation_id`\)/', $createSql)) {
        $errors[] = "mobile_user_tokens istnieje ze STARYM, BŁĘDNYM kluczem unikalności (user_id, installation_id) — "
            . "to pozwala dwóm różnym userom mieć jednocześnie aktywny token na tym samym urządzeniu. "
            . "'CREATE TABLE IF NOT EXISTS' tego automatycznie NIE naprawi. Wymagana ręczna naprawa — "
            . 'patrz docs/WITOSA-DEPLOYMENT.md, sekcja "Naprawa starego klucza unikalności", PRZED migracją.';
    } else {
        $warnings[] = "mobile_user_tokens istnieje, ale kształtu UNIQUE KEY nie udało się automatycznie rozpoznać — sprawdź ręcznie:\n$createSql";
    }
} else {
    echo "OK    mobile_user_tokens jeszcze nie istnieje — migracja 001 utworzy ją od razu w poprawnym kształcie\n";
}

// 5. mobile_meta — informacyjnie, nie krytyczne (bezpieczny no-op, jeśli już istnieje).
$result = $conn->query("SHOW TABLES LIKE 'mobile_meta'");
if ($result && $result->num_rows > 0) {
    echo "INFO  mobile_meta już istnieje — migracja 002 będzie no-opem (IF NOT EXISTS)\n";
} else {
    echo "OK    mobile_meta jeszcze nie istnieje\n";
}

// 6. Device-control-plane milestone: config/mobile_internal_api_secret.php
// must exist AND its secret must no longer be the shipped placeholder —
// session/login and webview/handoff both hard-depend on this being real.
$secretConfigPath = __DIR__ . '/public_html/config/mobile_internal_api_secret.php';
if (!file_exists($secretConfigPath)) {
    $errors[] = 'config/mobile_internal_api_secret.php nie istnieje — skopiuj go z paczki (public_html-additions/config/) przed kontynuowaniem.';
} else {
    require $secretConfigPath;
    if (!defined('MOBILE_INTERNAL_API_SECRET') || MOBILE_INTERNAL_API_SECRET === 'REPLACE_WITH_REAL_PER_PARISH_SECRET_FROM_ADMIN_PANEL') {
        $errors[] = 'MOBILE_INTERNAL_API_SECRET w config/mobile_internal_api_secret.php jest nadal placeholderem — wygeneruj prawdziwy sekret w panelu admina app.ministrant.eu dla tej parafii i wklej go tam przed kontynuowaniem.';
    } else {
        echo "OK    MOBILE_INTERNAL_API_SECRET jest ustawiony (nie placeholder)\n";
    }
}

echo "\n";

if (!empty($warnings)) {
    echo "OSTRZEŻENIA (nie blokują, ale sprawdź ręcznie):\n";
    foreach ($warnings as $w) {
        echo "  ⚠ $w\n";
    }
    echo "\n";
}

if (!empty($errors)) {
    echo "BŁĘDY — NIE URUCHAMIAJ MIGRACJI, dopóki nie zostaną rozwiązane:\n";
    foreach ($errors as $e) {
        echo "  ✗ $e\n";
    }
    exit(1);
}

echo "PREFLIGHT OK — bezpiecznie można przejść do migracji.\n";
exit(0);
