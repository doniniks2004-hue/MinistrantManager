<?php
declare(strict_types=1);

return [
    'key' => 'Witosa',
    'label' => 'Legacy Ministrant Manager / Witosa-compatible',
    'adapter_dir' => 'Witosa',
    'required_files' => [
        'config/database.php',
        'public/settings.php',
    ],
    'required_tables' => [
        'users',
        'events',
        'schedule',
        'announcements',
    ],
    'hardeners' => [
        'apply_legacy_security_hardening.php',
        'apply_legacy_web_hardening.php',
        'apply_substitution_hotfix.php',
    ],
    'install_meta' => 'ParishAdapters/Witosa/install_mobile_meta.php',
];
