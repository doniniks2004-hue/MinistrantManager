<?php
// Stable universal stub. The installer selects the active parish adapter
// in mobileapi-core/active-profile.php; this public file never changes
// between parishes or supported legacy versions.
define('MOBILEAPI_ENDPOINT', 'bootstrap.php');
require __DIR__ . '/../../../mobileapi-core/ParishAdapters/dispatch.php';
