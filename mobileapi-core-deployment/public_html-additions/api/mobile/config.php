<?php
// public_html/api/mobile/config.php
// Wymaga, żeby folder mobileapi-core/ leżał JEDEN POZIOM NAD public_html/
// (dokładnie tak samo jak .env już dziś leży poza public_html — patrz
// config/database.php) — czyli:
//   /home/<user>/mobileapi-core/...
//   /home/<user>/public_html/...   <- tu jesteśmy (w api/mobile/)
// Ścieżka względna — nic tu nie trzeba edytować per-serwer.
require __DIR__ . '/../../../mobileapi-core/ParishAdapters/Witosa/config.php';
