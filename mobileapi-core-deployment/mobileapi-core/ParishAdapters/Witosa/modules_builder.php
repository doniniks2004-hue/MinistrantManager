<?php

namespace MinistrantManager\MobileAPI\ParishAdapters\Witosa;

/**
 * Review round fix (WebView permissions): a SINGLE registry of every
 * legitimate WebView module — id, path, required_role — used by BOTH
 * build_modules() (what the dashboard shows) AND webview_handoff.php
 * (what a ticket may be minted for). Before this fix, webview_handoff.php
 * only checked the path against a flat list with no role information at
 * all — a Ministrant who knew (or guessed) the path to an admin-only
 * page like /public/users.php could mint a valid ticket for it, because
 * nothing there ever looked at the caller's role. Now there is exactly
 * ONE place role/path pairs are defined, so the two can never drift
 * apart the way a flat allowlist + a separate descriptor list could.
 *
 * `required_role: null` = every signed-in user. `enabled_check` is an
 * optional closure for the date/is_active-gated seasonal modules
 * (summer/kolenda/wyjazdy/triduum) — evaluated lazily, only when
 * build_modules() actually needs to decide whether to show the tile;
 * webview_handoff.php does NOT re-check `enabled_check` (see its own
 * docblock for why — briefly: a module some already has a valid ticket
 * for finishing its load after the window just closed is not a security
 * hole worth failing the request over).
 */
function webview_module_registry(): array
{
    $adminOrPriest = [1, 2];
    $adminOrPriestOrSenior = [1, 2, 3];

    return [
        'justifications' => [
            'title' => 'Usprawiedliwienia', 'path' => '/public/justifications.php',
            'icon' => 'note', 'order' => 60, 'required_role' => null,
        ],
        'substitution_finder' => [
            'title' => 'Znajdź zastępstwo', 'path' => '/public/substitution-finder.php',
            'icon' => 'search', 'order' => 45, 'required_role' => null,
        ],
        'summer' => [
            'title' => 'Kalendarz wakacyjny', 'path' => '/public/summer-calendar.php',
            'icon' => 'sun', 'order' => 70, 'required_role' => null,
            'enabled_check' => fn(\mysqli $conn) => _module_date_window_enabled($conn, 'summer_module'),
        ],
        'kolenda' => [
            'title' => 'Kolędy', 'path' => '/public/kolenda-calendar.php',
            'icon' => 'star', 'order' => 80, 'required_role' => null,
            'enabled_check' => fn(\mysqli $conn) => _module_date_window_enabled($conn, 'kolenda_module'),
        ],
        'wyjazdy' => [
            'title' => 'Wyjazdy i wydarzenia', 'path' => '/public/wyjazdy-kalendarz.php',
            'icon' => 'bus', 'order' => 90, 'required_role' => null,
            'enabled_check' => fn(\mysqli $conn) => _module_simple_active($conn, 'wyjazdy_module'),
        ],
        'triduum' => [
            'title' => 'Triduum Paschalne', 'path' => '/public/triduum.php',
            'icon' => 'church', 'order' => 100, 'required_role' => null,
            'enabled_check' => fn(\mysqli $conn) => _triduum_enabled($conn),
        ],
        'gathering_access' => [
            'title' => 'Obecność na zbiórkach', 'path' => '/public/gathering-access.php',
            'icon' => 'users', 'order' => 200, 'required_role' => $adminOrPriestOrSenior,
        ],
        'event_manager' => [
            'title' => 'Zwalnianie z mszy', 'path' => '/public/event_manager.php',
            'icon' => 'calendar-off', 'order' => 210, 'required_role' => $adminOrPriestOrSenior,
        ],
        'kandydaci' => [
            'title' => 'Kandydaci', 'path' => '/public/kandydaci-admin.php',
            'icon' => 'user-plus', 'order' => 220, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'custom_devotions' => [
            'title' => 'Nabożeństwa własne', 'path' => '/public/custom_devotions.php',
            'icon' => 'candle', 'order' => 230, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'points_management' => [
            'title' => 'Zarządzaj punktami', 'path' => '/public/points-management.php',
            'icon' => 'edit', 'order' => 240, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'users_admin' => [
            'title' => 'Użytkownicy', 'path' => '/public/users.php',
            'icon' => 'users-cog', 'order' => 250, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'statistics' => [
            'title' => 'Statystyki', 'path' => '/public/statistics.php',
            'icon' => 'chart', 'order' => 260, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'settings_admin' => [
            'title' => 'Ustawienia', 'path' => '/public/settings.php',
            'icon' => 'settings', 'order' => 270, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'parish_settings' => [
            'title' => 'Ustawienia parafii', 'path' => '/public/ustawienia.php',
            'icon' => 'settings', 'order' => 271, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'triduum_admin' => [
            'title' => 'Triduum — panel', 'path' => '/public/triduum-admin.php',
            'icon' => 'church', 'order' => 280, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],

        // Review round: pełna inwentaryzacja legacy (sidebar.php +
        // wszystkie pliki public/*.php). Wszystkie poniższe mają
        // potwierdzoną ochronę roli w samym pliku PHP
        // (`in_array($_SESSION['user_role_id'], [1, 2])` lub odpowiednik)
        // — nie zgadywane. Zobacz MODULE-MATRIX.md po pełne uzasadnienie
        // każdej pozycji.
        'summer_admin' => [
            'title' => 'Moduł letni — admin', 'path' => '/public/summer-admin.php',
            'icon' => 'sun', 'order' => 290, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'kolenda_admin' => [
            'title' => 'Kolędy — admin', 'path' => '/public/kolenda-admin.php',
            'icon' => 'star', 'order' => 291, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'kolenda_routes' => [
            'title' => 'Kolędy — podgląd tras', 'path' => '/public/kolenda-podglad.php',
            'icon' => 'star', 'order' => 292, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'wyjazdy_admin' => [
            'title' => 'Wyjazdy — admin', 'path' => '/public/wyjazdy-admin.php',
            'icon' => 'bus', 'order' => 293, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'meetings_config' => [
            'title' => 'Zarządzaj zbiórkami', 'path' => '/public/meetings-config.php',
            'icon' => 'users', 'order' => 300, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'msze_admin' => [
            'title' => 'Zarządzaj mszami', 'path' => '/public/msze.php',
            'icon' => 'church', 'order' => 301, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'parent_assignment' => [
            'title' => 'Przypisz rodzica', 'path' => '/public/parent-assignment.php',
            'icon' => 'user-plus', 'order' => 302, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'announcements_admin' => [
            // Celowo INNY moduł niż natywne "Ogłoszenia" (odczyt) —
            // to jest panel ZARZĄDZANIA (tworzenie/edycja) ogłoszeń.
            'title' => 'Zarządzaj ogłoszeniami', 'path' => '/public/announcements.php',
            'icon' => 'megaphone', 'order' => 303, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'groups_admin' => [
            'title' => 'Zarządzaj grupami', 'path' => '/public/groups.php',
            'icon' => 'users-cog', 'order' => 304, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'auto_generate_events' => [
            'title' => 'Niedziele i święta', 'path' => '/public/auto-generate-events.php',
            'icon' => 'calendar', 'order' => 305, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'generate_week' => [
            'title' => 'Msze w tygodniu', 'path' => '/public/generate-week.php',
            'icon' => 'calendar', 'order' => 306, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'nabozenstwa_admin' => [
            'title' => 'Nabożeństwa', 'path' => '/public/nabozenstwa.php',
            'icon' => 'candle', 'order' => 307, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'devotion_settings' => [
            'title' => 'Widoczność nabożeństw', 'path' => '/public/devotion_settings.php',
            'icon' => 'settings', 'order' => 308, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'church_attendance_check' => [
            'title' => 'Sprawdź obecność — tryb kościelnego', 'path' => '/public/church_attendance_check.php',
            'icon' => 'check', 'order' => 309, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'priest_attendance_review' => [
            'title' => 'Zatwierdź obecność', 'path' => '/public/priest_attendance_review.php',
            'icon' => 'check', 'order' => 310, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'devotional_ranking' => [
            'title' => 'Obecność na nabożeństwach', 'path' => '/public/devotional_ranking.php',
            'icon' => 'trophy', 'order' => 311, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'devotional_points_config' => [
            'title' => 'Punkty na nabożeństwach stałych', 'path' => '/public/devotional_points_config.php',
            'icon' => 'edit', 'order' => 312, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'triduum_attendance' => [
            'title' => 'Triduum — obecności', 'path' => '/public/triduum-attendance.php',
            'icon' => 'church', 'order' => 313, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'contact_form' => [
            'title' => 'Kontakt partnerski', 'path' => '/public/form.php',
            'icon' => 'note', 'order' => 320, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],

        // Znalezione przez przegląd public/*.php (potwierdzona ochrona
        // roli w pliku), ale NIEobecne w linkach sidebar.php — najpewniej
        // reachowane z innych stron admina (szczegóły/akcje), nie z
        // głównej nawigacji. Wystawione mimo to, żeby dało się je
        // otworzyć wprost z dashboardu bez utraty funkcji.
        'attendance_admin' => [
            'title' => 'Obecności — zarządzanie', 'path' => '/public/attendance.php',
            'icon' => 'check', 'order' => 330, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'attendance_history_admin' => [
            'title' => 'Obecności — historia', 'path' => '/public/attendance-history.php',
            'icon' => 'check', 'order' => 331, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'attendance_report_admin' => [
            'title' => 'Obecności — raport', 'path' => '/public/attendance-report.php',
            'icon' => 'chart', 'order' => 332, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'schedule_quick_edit' => [
            'title' => 'Szybka edycja grafiku', 'path' => '/public/schedule_quick_edit.php',
            'icon' => 'edit', 'order' => 333, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'manual_meeting' => [
            'title' => 'Ręczna zbiórka', 'path' => '/public/manual-meeting.php',
            'icon' => 'users', 'order' => 334, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'rotation_config' => [
            'title' => 'Konfiguracja rotacji służby', 'path' => '/public/rotation-config.php',
            'icon' => 'settings', 'order' => 335, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'mass_config' => [
            'title' => 'Konfiguracja mszy', 'path' => '/public/mass-config.php',
            'icon' => 'settings', 'order' => 336, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'sunday_mass_config' => [
            'title' => 'Konfiguracja mszy niedzielnych', 'path' => '/public/sunday_mass_config.php',
            'icon' => 'settings', 'order' => 337, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'sunday_mass_generator' => [
            'title' => 'Generator mszy niedzielnych', 'path' => '/public/sunday_mass_generator.php',
            'icon' => 'calendar', 'order' => 338, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'user_add' => [
            'title' => 'Dodaj użytkownika', 'path' => '/public/user-add.php',
            'icon' => 'user-plus', 'order' => 339, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'user_edit' => [
            'title' => 'Edytuj użytkownika', 'path' => '/public/user-edit.php',
            'icon' => 'edit', 'order' => 340, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'import_users' => [
            'title' => 'Import użytkowników', 'path' => '/public/import-users.php',
            'icon' => 'users-cog', 'order' => 341, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'akcept' => [
            'title' => 'Akceptacja', 'path' => '/public/akcept.php',
            'icon' => 'check', 'order' => 342, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],

        // Verified against the current Witosa legacy source:
        // both manual-swap.php and senior-managers.php explicitly allow
        // only Admin/Ksiądz (roles 1/2). Keep the handoff registry exactly
        // aligned with the page-level authorization.
        'manual_swap' => [
            'title' => 'Ręczna zamiana', 'path' => '/public/manual-swap.php',
            'icon' => 'swap', 'order' => 343, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],
        'senior_managers' => [
            'title' => 'Starsi ministranci — zarządzanie', 'path' => '/public/senior-managers.php',
            'icon' => 'users-cog', 'order' => 344, 'required_role' => $adminOrPriest, 'section' => 'config',
        ],

        // Statyczne strony publiczne — dostępne każdemu zalogowanemu,
        // niska częstotliwość użycia.
        'privacy_policy' => [
            'title' => 'Polityka prywatności', 'path' => '/public/polityka-prywatnosci.php',
            'icon' => 'note', 'order' => 400, 'required_role' => null,
        ],
        'terms' => [
            'title' => 'Regulamin', 'path' => '/public/regulamin.php',
            'icon' => 'note', 'order' => 401, 'required_role' => null,
        ],
    ];
}

/**
 * Builds the `modules` array for GET /mobile/config. Backward
 * compatible: `capabilities` is untouched and still returned alongside
 * this. NOT role-filtered here — config.php is callable before login —
 * each descriptor carries `required_role` for the Flutter dashboard's
 * DISPLAY-only filter (real enforcement is webview_handoff.php's role
 * check below, and bootstrap.php's own per-user filtering for native data).
 *
 * All 7 P1 native modules (schedule/ranking/points/substitutions/
 * attendance/announcements/profile) now have real Flutter screens and
 * are listed as `native` below — see MODULE-MATRIX.md for the full,
 * per-module DONE/PARTIAL status. A module is only ever added here as
 * `native` once its screen genuinely ships in the same commit — never
 * ahead of it (an earlier round briefly advertised these before the
 * screens existed; see that commit's own note on why that was wrong).
 */
function build_modules(\mysqli $conn): array
{
    $modules = [
        ['id' => 'schedule', 'title' => 'Mój grafik', 'type' => 'native', 'screen' => 'my_schedule',
            'icon' => 'calendar', 'order' => 10, 'enabled' => true, 'requires_online' => false, 'required_role' => null],
        ['id' => 'ranking', 'title' => 'Ranking', 'type' => 'native', 'screen' => 'ranking',
            'icon' => 'trophy', 'order' => 20, 'enabled' => true, 'requires_online' => false, 'required_role' => null],
        ['id' => 'points', 'title' => 'Historia punktów', 'type' => 'native', 'screen' => 'points_history',
            'icon' => 'star', 'order' => 30, 'enabled' => true, 'requires_online' => false, 'required_role' => null],
        ['id' => 'substitutions', 'title' => 'Zastępstwa', 'type' => 'native', 'screen' => 'substitutions',
            'icon' => 'swap', 'order' => 40, 'enabled' => true, 'requires_online' => false, 'required_role' => null],
        ['id' => 'attendance', 'title' => 'Obecności', 'type' => 'native', 'screen' => 'attendance',
            'icon' => 'check', 'order' => 45, 'enabled' => true, 'requires_online' => false, 'required_role' => null],
        ['id' => 'announcements', 'title' => 'Ogłoszenia', 'type' => 'native', 'screen' => 'announcements',
            'icon' => 'megaphone', 'order' => 50, 'enabled' => true, 'requires_online' => false, 'required_role' => null],
        ['id' => 'profile', 'title' => 'Moje konto', 'type' => 'native', 'screen' => 'profile',
            'icon' => 'user', 'order' => 900, 'enabled' => true, 'requires_online' => false, 'required_role' => null],
    ];

    foreach (webview_module_registry() as $id => $def) {
        if (isset($def['enabled_check']) && !$def['enabled_check']($conn)) {
            continue;
        }
        $modules[] = [
            'id' => $id, 'title' => $def['title'], 'type' => 'webview', 'path' => $def['path'],
            'icon' => $def['icon'], 'order' => $def['order'], 'enabled' => true,
            'requires_online' => true, 'required_role' => $def['required_role'],
            'section' => $def['section'] ?? null,
        ];
    }

    usort($modules, fn($a, $b) => $a['order'] <=> $b['order']);

    return $modules;
}

function _module_simple_active(\mysqli $conn, string $table): bool
{
    // Defensive: a parish that never enabled this optional legacy module
    // may not even have this table created at all — never crash the
    // whole /mobile/config response over one optional module's absence.
    try {
        $result = @$conn->query("SELECT is_active FROM `$table` WHERE id = 1");
    } catch (\mysqli_sql_exception $e) {
        return false;
    }
    if (!$result) {
        return false;
    }
    $row = $result->fetch_assoc();
    return $row && (bool) $row['is_active'];
}

function _module_date_window_enabled(\mysqli $conn, string $table): bool
{
    try {
        $result = @$conn->query("SELECT is_active, date_from, date_to FROM `$table` WHERE id = 1");
    } catch (\mysqli_sql_exception $e) {
        return false;
    }
    if (!$result) {
        return false;
    }
    $row = $result->fetch_assoc();
    if (!$row || !$row['is_active']) {
        return false;
    }
    $today = date('Y-m-d');
    $afterStart = !$row['date_from'] || $today >= $row['date_from'];
    $beforeEnd = !$row['date_to'] || $today <= $row['date_to'];
    return $afterStart && $beforeEnd;
}

function _triduum_enabled(\mysqli $conn): bool
{
    try {
        $result = @$conn->query(
            "SELECT setting_key, setting_value FROM triduum_config WHERE setting_key IN ('module_enabled','module_completely_hidden') LIMIT 2"
        );
    } catch (\mysqli_sql_exception $e) {
        return false;
    }
    if (!$result) {
        return false;
    }
    $cfg = [];
    while ($row = $result->fetch_assoc()) {
        $cfg[$row['setting_key']] = $row['setting_value'];
    }
    $enabled = ($cfg['module_enabled'] ?? '0') === '1';
    $hidden = ($cfg['module_completely_hidden'] ?? '0') === '1';
    return $enabled && !$hidden;
}
