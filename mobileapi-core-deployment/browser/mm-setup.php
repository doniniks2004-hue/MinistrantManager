<?php
declare(strict_types=1);
// Copy ONLY this file into public_html; the package stays outside the web root.
$controller = dirname(__DIR__) . '/mm-installer/browser/controller.php';
if (!is_file($controller)) { http_response_code(404); exit('Installer package missing.'); }
require $controller;
