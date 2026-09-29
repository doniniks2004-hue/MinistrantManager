<?php
/**
 * GET /api/v1/mobile/config
 *
 * Reads the ONE precomputed `mobile_meta` row (populated by
 * install_mobile_meta.php at adapter install/update time — Iteration 2
 * point 9) rather than probing which of the 80+ legacy tables exist on
 * every request. The app is expected to hide/disable any section whose
 * capability is `false` here, never treat a missing module as an error.
 *
 * Requires only a valid device (no user token) — this is fleet/parish-
 * level config the app needs BEFORE a user has logged in, same spirit as
 * app.ministrant.eu's GET /api/client-config from Iteration 1.
 */

require __DIR__ . '/wiring.php';
require __DIR__ . '/modules_builder.php';

use MinistrantManager\MobileAPI\Http\JsonResponse;
use function MinistrantManager\MobileAPI\ParishAdapters\Witosa\build_modules;

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') {
    JsonResponse::error('method_not_allowed', 'Wymagane GET.', 405);
}

$ctx = mobileapi_device_context();

$result = $conn->query('SELECT schema_version, adapter_version, capabilities_json, updated_at FROM mobile_meta WHERE id = 1');
$row = $result ? $result->fetch_assoc() : null;

if ($row === null) {
    // mobile_meta not installed yet on this parish — fail closed with a
    // clear, specific error rather than a generic 500, so an app build
    // pointed at a not-yet-migrated parish gets an actionable message.
    JsonResponse::error('adapter_not_installed', 'MobileAPI adapter nie jest jeszcze zainstalowany na tej parafii.', 503);
}

$capabilities = json_decode($row['capabilities_json'], true);
if (!is_array($capabilities)) {
    $capabilities = [];
}

// Review round (hybrid dashboard milestone): `modules` is NEW and
// additive — an old app build that only reads `capabilities` keeps
// working unchanged; a new build reads this richer descriptor instead.
// Computed fresh on every request (not cached in mobile_meta) because
// triduum/summer/kolenda/wyjazdy enablement is date-window-dependent —
// see modules_builder.php's docblock.
$modules = build_modules($conn);

JsonResponse::success([
    'schema_version' => (int) $row['schema_version'],
    'adapter_version' => $row['adapter_version'],
    'capabilities' => $capabilities,
    'modules' => $modules,
    'updated_at' => $row['updated_at'],
]);
