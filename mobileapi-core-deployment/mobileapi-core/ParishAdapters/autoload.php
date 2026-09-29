<?php
/**
 * Minimal PSR-4-style autoloader for the MinistrantManager\MobileAPI\*
 * namespace. No Composer, no vendor/ — parishes run plain PHP files
 * (Iteration 2 point 2). Drop the entire `mobileapi/` package folder
 * somewhere on the parish's filesystem (convention: OUTSIDE public_html,
 * next to the parish's own .env — see wiring.php) and require THIS one
 * file from any entrypoint that needs MobileAPI classes.
 */

spl_autoload_register(function (string $class) {
    $prefix = 'MinistrantManager\\MobileAPI\\';
    if (strncmp($class, $prefix, strlen($prefix)) !== 0) {
        return; // not ours — let another autoloader (if any) handle it
    }

    $relative = substr($class, strlen($prefix));
    $path = __DIR__ . '/../' . str_replace('\\', '/', $relative) . '.php';

    if (is_file($path)) {
        require $path;
    }
});
