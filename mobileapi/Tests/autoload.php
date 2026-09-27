<?php
// Minimal PSR-4-style autoloader for THIS package only. Not a substitute
// for `composer install` in the real project (which will also need
// Laravel's own container/facades for the Controllers/Middleware — those
// genuinely cannot run without the framework). This exists purely so the
// framework-FREE parts of MobileAPI (DTO, Contracts, Actions, and the Fake
// repositories) can be exercised by a real PHP process in an environment
// with no Composer/Packagist access, proving their logic actually works.
spl_autoload_register(function ($class) {
    $prefix = 'MinistrantManager\\MobileAPI\\';
    if (!str_starts_with($class, $prefix)) {
        return;
    }
    $relative = substr($class, strlen($prefix));
    $path = __DIR__ . '/../' . str_replace('\\', '/', $relative) . '.php';
    if (is_file($path)) {
        require $path;
    }
});
