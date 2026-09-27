<?php

namespace MinistrantManager\MobileAPI\Config;

/**
 * Spec §17 + decision #13: the fixed vocabulary of components the mobile
 * app knows how to render from server-sent JSON. THIS LIST IS THE
 * CONTRACT — the client treats anything not in it as "unsupported" and
 * falls back safely (spec decision #13), never crashes, never evaluates
 * arbitrary code (no JS, no HTML, no Dart from the server — ever).
 */
final class ServerDrivenUiSchema
{
    public const SCHEMA_VERSION = 1;

    public const KNOWN_COMPONENTS = [
        'card', 'stat_card', 'text', 'info_box', 'status_badge',
        'list', 'event_list', 'calendar', 'button', 'tabs', 'simple_form',
    ];

    public static function isKnownComponent(string $component): bool
    {
        return in_array($component, self::KNOWN_COMPONENTS, true);
    }

    /**
     * Validates a dashboard config payload's SHAPE (not its business
     * meaning) before it's ever sent to a device — catches an admin/CMS
     * mistake (typo'd component name, missing required field) at
     * config-authoring time rather than crashing the app.
     *
     * @return string[] list of validation error messages (empty = valid)
     */
    public static function validateDashboardConfig(array $config): array
    {
        $errors = [];

        if (($config['schema_version'] ?? null) !== self::SCHEMA_VERSION) {
            $errors[] = 'schema_version must be ' . self::SCHEMA_VERSION;
        }

        foreach ($config['dashboard']['items'] ?? [] as $i => $item) {
            if (empty($item['module_id'])) {
                $errors[] = "dashboard.items[$i].module_id is required";
            }
            if (!isset($item['order']) || !is_int($item['order'])) {
                $errors[] = "dashboard.items[$i].order must be an integer";
            }
        }

        foreach ($config['modules'] ?? [] as $i => $module) {
            if (empty($module['id'])) {
                $errors[] = "modules[$i].id is required";
            }
            if (empty($module['component'])) {
                $errors[] = "modules[$i].component is required";
            } elseif (!self::isKnownComponent($module['component'])) {
                // Deliberately NOT an error — spec decision #13: an
                // unknown component must not break config authoring
                // either. It becomes the client's job to skip/fallback at
                // render time. We still surface it as a warning-shaped
                // string so an admin UI CAN choose to flag it.
                $errors[] = "warning: modules[$i].component '{$module['component']}' is not in the known component list (client will show a safe fallback, not fail)";
            }
            if (!empty($module['min_app_version']) && !preg_match('/^\d+\.\d+\.\d+$/', $module['min_app_version'])) {
                $errors[] = "modules[$i].min_app_version must be semver (x.y.z)";
            }
        }

        return $errors;
    }
}
