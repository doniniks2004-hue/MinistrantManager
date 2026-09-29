<?php

namespace MinistrantManager\MobileAPI\ParishAdapters\Witosa;

/**
 * Builds the `modules` array for GET /mobile/config (review round,
 * hybrid dashboard milestone). Backward compatible: `capabilities`
 * (Iteration 2) is untouched and still returned alongside this — an app
 * build that doesn't know about `modules` yet keeps working exactly as
 * before; only a build that understands it gets the richer descriptor.
 *
 * Deliberately NOT role-filtered here — config.php is callable BEFORE
 * login (device-only), so it has no user/role to filter by. Each
 * descriptor instead carries `required_role` (null = everyone signed
 * in; an array of role_ids = only those roles), and the FLUTTER
 * dashboard applies this using the role_id already returned by
 * `/session/login`. This is a DISPLAY filter only — review round point
 * 22 ("nie ufamy tylko UI"): the actual data/webview-handoff endpoints
 * enforce role checks server-side independently of what the client
 * chooses to show.
 *
 * `enabled` for triduum/summer/kolenda/wyjazdy mirrors
 * src/partials/sidebar.php's OWN enable logic exactly (same tables,
 * same is_active + date_from/date_to window check) — this is the single
 * source of truth the real web app already uses; this function doesn't
 * invent a second one.
 */
function build_modules(\mysqli $conn): array
{
    $modules = [];

    // --- Native modules (always present; role/plan gating happens via required_role) ---

    $modules[] = [
        'id' => 'schedule', 'title' => 'Mój grafik', 'type' => 'native', 'screen' => 'my_schedule',
        'icon' => 'calendar', 'order' => 10, 'enabled' => true, 'requires_online' => false, 'required_role' => null,
    ];
    $modules[] = [
        'id' => 'ranking', 'title' => 'Ranking', 'type' => 'native', 'screen' => 'ranking',
        'icon' => 'trophy', 'order' => 20, 'enabled' => true, 'requires_online' => false, 'required_role' => null,
    ];
    $modules[] = [
        'id' => 'points', 'title' => 'Historia punktów', 'type' => 'native', 'screen' => 'points_history',
        'icon' => 'star', 'order' => 30, 'enabled' => true, 'requires_online' => false, 'required_role' => null,
    ];
    $modules[] = [
        'id' => 'substitutions', 'title' => 'Zastępstwa', 'type' => 'native', 'screen' => 'substitutions',
        'icon' => 'swap', 'order' => 40, 'enabled' => true, 'requires_online' => false, 'required_role' => null,
    ];
    $modules[] = [
        'id' => 'announcements', 'title' => 'Ogłoszenia', 'type' => 'native', 'screen' => 'announcements',
        'icon' => 'megaphone', 'order' => 50, 'enabled' => true, 'requires_online' => false, 'required_role' => null,
    ];
    $modules[] = [
        'id' => 'profile', 'title' => 'Moje konto', 'type' => 'native', 'screen' => 'profile',
        'icon' => 'user', 'order' => 900, 'enabled' => true, 'requires_online' => false, 'required_role' => null,
    ];

    // --- WebView modules: everyday legacy, read/write via existing PHP ---

    $modules[] = [
        'id' => 'justifications', 'title' => 'Usprawiedliwienia', 'type' => 'webview', 'path' => '/public/justifications.php',
        'icon' => 'note', 'order' => 60, 'enabled' => true, 'requires_online' => true, 'required_role' => null,
    ];
    $modules[] = [
        'id' => 'substitution_finder', 'title' => 'Znajdź zastępstwo', 'type' => 'webview', 'path' => '/public/substitution-finder.php',
        'icon' => 'search', 'order' => 45, 'enabled' => true, 'requires_online' => true, 'required_role' => null,
    ];

    // --- WebView modules: conditionally enabled, mirroring sidebar.php exactly ---

    if (_module_date_window_enabled($conn, 'summer_module')) {
        $modules[] = [
            'id' => 'summer', 'title' => 'Kalendarz wakacyjny', 'type' => 'webview', 'path' => '/public/summer-calendar.php',
            'icon' => 'sun', 'order' => 70, 'enabled' => true, 'requires_online' => true, 'required_role' => null,
        ];
    }
    if (_module_date_window_enabled($conn, 'kolenda_module')) {
        $modules[] = [
            'id' => 'kolenda', 'title' => 'Kolędy', 'type' => 'webview', 'path' => '/public/kolenda-calendar.php',
            'icon' => 'star', 'order' => 80, 'enabled' => true, 'requires_online' => true, 'required_role' => null,
        ];
    }
    if (_module_simple_active($conn, 'wyjazdy_module')) {
        $modules[] = [
            'id' => 'wyjazdy', 'title' => 'Wyjazdy i wydarzenia', 'type' => 'webview', 'path' => '/public/wyjazdy-kalendarz.php',
            'icon' => 'bus', 'order' => 90, 'enabled' => true, 'requires_online' => true, 'required_role' => null,
        ];
    }
    if (_triduum_enabled($conn)) {
        $modules[] = [
            'id' => 'triduum', 'title' => 'Triduum Paschalne', 'type' => 'webview', 'path' => '/public/triduum.php',
            'icon' => 'church', 'order' => 100, 'enabled' => true, 'requires_online' => true, 'required_role' => null,
        ];
    }

    // --- WebView modules: administrative/rare — role-gated (Admin=1, Ksiądz=2, Starszy=3) ---

    $adminOrPriest = [1, 2];
    $adminOrPriestOrSenior = [1, 2, 3];

    $modules[] = [
        'id' => 'gathering_access', 'title' => 'Obecność na zbiórkach', 'type' => 'webview', 'path' => '/public/gathering-access.php',
        'icon' => 'users', 'order' => 200, 'enabled' => true, 'requires_online' => true, 'required_role' => $adminOrPriestOrSenior,
    ];
    $modules[] = [
        'id' => 'event_manager', 'title' => 'Zwalnianie z mszy', 'type' => 'webview', 'path' => '/public/event_manager.php',
        'icon' => 'calendar-off', 'order' => 210, 'enabled' => true, 'requires_online' => true, 'required_role' => $adminOrPriestOrSenior,
    ];
    $modules[] = [
        'id' => 'kandydaci', 'title' => 'Kandydaci', 'type' => 'webview', 'path' => '/public/kandydaci-admin.php',
        'icon' => 'user-plus', 'order' => 220, 'enabled' => true, 'requires_online' => true, 'required_role' => $adminOrPriest,
    ];
    $modules[] = [
        'id' => 'custom_devotions', 'title' => 'Nabożeństwa własne', 'type' => 'webview', 'path' => '/public/custom_devotions.php',
        'icon' => 'candle', 'order' => 230, 'enabled' => true, 'requires_online' => true, 'required_role' => $adminOrPriest,
    ];
    $modules[] = [
        'id' => 'points_management', 'title' => 'Zarządzaj punktami', 'type' => 'webview', 'path' => '/public/points-management.php',
        'icon' => 'edit', 'order' => 240, 'enabled' => true, 'requires_online' => true, 'required_role' => $adminOrPriest,
    ];
    $modules[] = [
        'id' => 'users_admin', 'title' => 'Użytkownicy', 'type' => 'webview', 'path' => '/public/users.php',
        'icon' => 'users-cog', 'order' => 250, 'enabled' => true, 'requires_online' => true, 'required_role' => $adminOrPriest,
    ];
    $modules[] = [
        'id' => 'statistics', 'title' => 'Statystyki', 'type' => 'webview', 'path' => '/public/statistics.php',
        'icon' => 'chart', 'order' => 260, 'enabled' => true, 'requires_online' => true, 'required_role' => $adminOrPriest,
    ];
    $modules[] = [
        'id' => 'settings_admin', 'title' => 'Ustawienia', 'type' => 'webview', 'path' => '/public/settings.php',
        'icon' => 'settings', 'order' => 270, 'enabled' => true, 'requires_online' => true, 'required_role' => $adminOrPriest,
    ];
    $modules[] = [
        'id' => 'triduum_admin', 'title' => 'Triduum — panel', 'type' => 'webview', 'path' => '/public/triduum-admin.php',
        'icon' => 'church', 'order' => 280, 'enabled' => true, 'requires_online' => true, 'required_role' => $adminOrPriest,
    ];

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

/**
 * The full set of legitimate WebView target paths for this parish,
 * regardless of current enabled/role state — used by webview_handoff.php
 * to reject a ticket request for anything NOT in this list (review round
 * point 18: never mint a ticket for an arbitrary attacker-supplied
 * path). Deliberately a flat list independent of build_modules()'s
 * per-request enabled/role computation — a path is either a legitimate
 * module of THIS parish's app or it isn't; whether it's CURRENTLY shown
 * on the dashboard is a separate, less security-critical concern.
 */
function webview_path_allowlist(): array
{
    return [
        '/public/justifications.php',
        '/public/substitution-finder.php',
        '/public/summer-calendar.php',
        '/public/kolenda-calendar.php',
        '/public/wyjazdy-kalendarz.php',
        '/public/triduum.php',
        '/public/gathering-access.php',
        '/public/event_manager.php',
        '/public/kandydaci-admin.php',
        '/public/custom_devotions.php',
        '/public/points-management.php',
        '/public/users.php',
        '/public/statistics.php',
        '/public/settings.php',
        '/public/triduum-admin.php',
    ];
}
