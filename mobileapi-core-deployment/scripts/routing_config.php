<?php
declare(strict_types=1);

function canonicalMobileRouting(string $current, string $snippet): string
{
    $current = preg_replace('/# BEGIN MINISTRANT MANAGER MOBILEAPI.*?# END MINISTRANT MANAGER MOBILEAPI\s*/s', '', $current) ?? $current;
    // Repair stray wrappers from older installers that wrapped an already
    // wrapped snippet. The snippet shipped now deliberately has no markers.
    $current = preg_replace('/^# (?:BEGIN|END) MINISTRANT MANAGER MOBILEAPI\s*\R?/m', '', $current) ?? $current;
    return "# BEGIN MINISTRANT MANAGER MOBILEAPI\n" . trim($snippet)
        . "\n# END MINISTRANT MANAGER MOBILEAPI\n\n" . ltrim($current);
}
