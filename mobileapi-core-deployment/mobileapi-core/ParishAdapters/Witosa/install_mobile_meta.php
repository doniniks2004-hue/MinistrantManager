<?php
/**
 * Run ONCE per parish install/update (CLI: `php install_mobile_meta.php`),
 * never from an HTTP entrypoint. Iteration 2 point 9: capability detection
 * happens HERE, at install time, not on every request.
 *
 * For Witosa specifically, at this milestone: only events + schedule are
 * wired to a real Legacy adapter (Krok 3D/3E) — everything else reports
 * false until its own adapter exists, even though the underlying legacy
 * tables (points, announcements, substitution_requests, ...) already
 * exist in Witosa's real database. "The table exists" and "MobileAPI has
 * a working adapter for it" are deliberately different questions; this
 * file answers the second one, not the first.
 */

require __DIR__ . '/wiring.php';

$capabilities = [
    'events' => true,
    'schedule' => true,
    'attendance' => false,   // schedule.is_present exists but has no dedicated adapter/endpoint yet; gathering_attendance not mapped at all yet
    'points' => false,
    'ranking' => false,
    'substitutions' => false,
    'announcements' => true, // hybrid dashboard milestone P1 — LegacyMysqlAnnouncementsRepository wired into bootstrap.php
];

$capabilitiesJson = json_encode($capabilities, JSON_UNESCAPED_UNICODE);

$stmt = $conn->prepare(
    'INSERT INTO mobile_meta (id, schema_version, adapter_version, capabilities_json, installed_at, updated_at)
     VALUES (1, ?, ?, ?, NOW(), NOW())
     ON DUPLICATE KEY UPDATE
        schema_version = VALUES(schema_version),
        adapter_version = VALUES(adapter_version),
        capabilities_json = VALUES(capabilities_json),
        updated_at = NOW()'
);
$schemaVersion = 1;
$adapterVersion = '2.1.0-hybrid-dashboard'; // this vertical slice — bump with each real capability added
$stmt->bind_param('iss', $schemaVersion, $adapterVersion, $capabilitiesJson);
$stmt->execute();
$stmt->close();

echo "mobile_meta installed/updated: schema_version=$schemaVersion, adapter_version=$adapterVersion\n";
echo "capabilities: $capabilitiesJson\n";
