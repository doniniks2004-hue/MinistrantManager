<?php
declare(strict_types=1);

return [
    'key' => 'Witosa',
    'label' => 'Legacy Ministrant Manager / Witosa-compatible',
    'adapter_dir' => 'Witosa',
    // Only files required by MobileAPI itself belong here. Legacy UI
    // files such as public/settings.php are intentionally NOT required:
    // some parishes use trimmed/custom builds.
    'required_files' => [
        'config/database.php',
    ],
    'required_tables' => [
        'users',
        'events',
        'schedule',
        'announcements',
    ],
    // Universal backup covers every legacy file that this profile's
    // hardeners may change. Their own atomic backups remain an
    // additional second layer.
    'legacy_backup_files' => [
        'config/database.php',
        'upd.php',
        'reset.php',
        'receiver.php',
        'fix.php',
        'public/settings.php',
        'public/empty.php',
        'public/form.php',
        'public/substitution-finder.php',
        'public/substitution-ajax.php',
        'public/substitution-functions.php',
        'public/event-details.php',
        'public/js/script.js',
        'public/manual-swap.php',
        'api/request_substitution.php',
        'api/accept_substitution.php',
        'public/substitution-security.php',
    ],
    // Legacy hardening is advisory/optional and must never block
    // installation of the isolated MobileAPI layer.
    'hardeners' => [],
    'optional_hardeners' => [
        'apply_legacy_security_hardening.php',
        'apply_legacy_web_hardening.php',
        'apply_substitution_hotfix.php',
    ],
    'install_meta' => 'ParishAdapters/Witosa/install_mobile_meta.php',
];
