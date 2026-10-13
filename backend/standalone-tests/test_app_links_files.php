<?php

declare(strict_types=1);

/**
 * Universal Links / App Links association files (spec §35):
 *  - both are valid JSON of the shape each platform expects;
 *  - the iOS one lists /activate/* for an app ID built from the real bundle id;
 *  - the .well-known/.htaccess forces application/json for BOTH (the iOS file
 *    has no extension, so its type cannot be guessed);
 *  - the Android package name matches the one the app is built with.
 *
 * The iOS Team ID is still a placeholder until an Apple Developer account
 * exists; that is REPORTED, not failed, so this test stays green while it is
 * the only thing missing and goes on guarding the rest.
 */

$dir = __DIR__ . '/../public/.well-known';
$failures = [];
$check = static function (bool $ok, string $what) use (&$failures): void {
    if (!$ok) $failures[] = $what;
};

// ---- iOS
$aasaRaw = (string) @file_get_contents($dir . '/apple-app-site-association');
$aasa = json_decode($aasaRaw, true);
$check(is_array($aasa), 'apple-app-site-association is not valid JSON');
$details = $aasa['applinks']['details'][0] ?? [];
$check(isset($aasa['applinks']['apps']) && $aasa['applinks']['apps'] === [], 'applinks.apps must be an empty array');
$check(in_array('/activate/*', $details['paths'] ?? [], true), 'AASA must list /activate/*');
$appId = (string) ($details['appID'] ?? '');
$check(str_ends_with($appId, '.__APPLE_BUNDLE_ID__') || str_ends_with($appId, '.eu.ministrant.manager'),
    'AASA appID must end with the bundle id eu.ministrant.manager (or its placeholder)');
$placeholder = str_contains($appId, '__APPLE_TEAM_ID__');

// ---- Android
$links = json_decode((string) @file_get_contents($dir . '/assetlinks.json'), true);
$check(is_array($links), 'assetlinks.json is not valid JSON');
$target = $links[0]['target'] ?? [];
$check(($target['package_name'] ?? '') === 'eu.ministrant.manager', 'assetlinks package_name must be eu.ministrant.manager');
$check(!empty($target['sha256_cert_fingerprints']), 'assetlinks must list a certificate fingerprint');

// ---- content type
$htaccess = (string) @file_get_contents($dir . '/.htaccess');
$check(preg_match('/<Files\s+"apple-app-site-association">\s*ForceType\s+application\/json/s', $htaccess) === 1,
    '.well-known/.htaccess must force application/json for apple-app-site-association');
$check(preg_match('/<Files\s+"assetlinks\.json">\s*ForceType\s+application\/json/s', $htaccess) === 1,
    '.well-known/.htaccess must force application/json for assetlinks.json');

// ---- the iOS entitlement the app is built with must name the same domain
$ent = (string) @file_get_contents(__DIR__ . '/../../mobile-ios/ios/Runner/Runner.entitlements');
if ($ent !== '') {
    $check(str_contains($ent, 'applinks:app.ministrant.eu'), 'Runner.entitlements must declare applinks:app.ministrant.eu');
}

if ($failures !== []) {
    fwrite(STDERR, "test_app_links_files FAILED:\n - " . implode("\n - ", $failures) . "\n");
    exit(1);
}
echo "test_app_links_files OK\n";
if ($placeholder) {
    echo "NOTE: the iOS Team ID in apple-app-site-association is still a placeholder (needs an Apple Developer account).\n";
}
