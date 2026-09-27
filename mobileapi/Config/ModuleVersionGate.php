<?php

namespace MinistrantManager\MobileAPI\Config;

/**
 * Spec §18: a module can require a newer app version than the requesting
 * device has. Pure semver-ish comparison (major.minor.patch), shared
 * logic between (eventually) a server-side filter — hide modules the
 * device can't run at all from its config response — and the client's
 * own "Zaktualizuj aplikację" gate as a second line of defense.
 */
final class ModuleVersionGate
{
    public static function isSupported(string $deviceAppVersion, ?string $moduleMinVersion): bool
    {
        if ($moduleMinVersion === null) {
            return true;
        }
        return version_compare($deviceAppVersion, $moduleMinVersion, '>=');
    }

    /**
     * Filters a module list down to those the given device app version can
     * actually run, annotating the rest as unsupported rather than
     * dropping them silently — a client that wants to show "coming soon
     * once you update" can use the annotation instead of just not knowing
     * the module exists.
     */
    public static function annotate(array $modules, string $deviceAppVersion): array
    {
        return array_map(function ($module) use ($deviceAppVersion) {
            $module['supported_on_this_version'] = self::isSupported($deviceAppVersion, $module['min_app_version'] ?? null);
            return $module;
        }, $modules);
    }
}
