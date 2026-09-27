<?php
require __DIR__ . '/autoload.php';

use MinistrantManager\MobileAPI\Config\ModuleVersionGate;
use MinistrantManager\MobileAPI\Config\ServerDrivenUiSchema;

function assertTrue(bool $cond, string $msg): void {
    if (!$cond) { fwrite(STDERR, "FAIL: $msg\n"); exit(1); }
    echo "PASS: $msg\n";
}
function assertEquals($expected, $actual, string $msg): void {
    if ($expected !== $actual) {
        fwrite(STDERR, "FAIL: $msg (expected " . var_export($expected, true) . ", got " . var_export($actual, true) . ")\n");
        exit(1);
    }
    echo "PASS: $msg\n";
}

// --- ServerDrivenUiSchema ---
assertTrue(ServerDrivenUiSchema::isKnownComponent('event_list'), 'event_list is a known component');
assertTrue(!ServerDrivenUiSchema::isKnownComponent('video_player'), 'video_player is NOT a known component (must fall back safely, never crash)');

$validConfig = [
    'schema_version' => 1,
    'dashboard' => ['layout' => 'grid', 'columns' => 2, 'items' => [
        ['module_id' => 'schedule', 'order' => 1],
        ['module_id' => 'points', 'order' => 2],
    ]],
    'modules' => [
        ['id' => 'schedule', 'component' => 'event_list', 'min_app_version' => '1.0.0'],
    ],
];
assertEquals([], ServerDrivenUiSchema::validateDashboardConfig($validConfig), 'a well-formed config has zero validation errors');

$brokenConfig = [
    'schema_version' => 2, // wrong on purpose
    'dashboard' => ['items' => [['order' => 'not-an-int']]], // missing module_id, bad order type
    'modules' => [['id' => 'triduum', 'component' => 'video_player']], // unknown component
];
$errors = ServerDrivenUiSchema::validateDashboardConfig($brokenConfig);
assertTrue(count($errors) >= 3, 'a malformed config surfaces multiple distinct problems, not just the first one');
assertTrue(str_contains(implode(' ', $errors), 'schema_version'), 'wrong schema_version is caught');
assertTrue(str_contains(implode(' ', $errors), 'module_id'), 'missing module_id is caught');

// --- ModuleVersionGate (spec §18) ---
assertTrue(ModuleVersionGate::isSupported('2.4.0', '2.4.0'), 'exact version match is supported');
assertTrue(ModuleVersionGate::isSupported('2.5.0', '2.4.0'), 'newer device version is supported');
assertTrue(!ModuleVersionGate::isSupported('2.1.0', '2.4.0'), 'older device version (2.1.0 < required 2.4.0) is NOT supported — spec §18 verbatim example');
assertTrue(ModuleVersionGate::isSupported('1.0.0', null), 'a module with no min_app_version is supported on any version');

$annotated = ModuleVersionGate::annotate([
    ['id' => 'triduum', 'min_app_version' => '2.4.0'],
    ['id' => 'schedule', 'min_app_version' => null],
], deviceAppVersion: '2.1.0');
assertEquals(false, $annotated[0]['supported_on_this_version'], 'triduum module correctly flagged unsupported on 2.1.0');
assertEquals(true, $annotated[1]['supported_on_this_version'], 'schedule module (no version requirement) correctly flagged supported');

echo "\nAll Config contract tests passed (server-driven UI safety net + spec §18 version gating).\n";
