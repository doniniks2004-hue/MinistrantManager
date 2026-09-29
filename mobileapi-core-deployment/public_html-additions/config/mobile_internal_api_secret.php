<?php
// Plik: config/mobile_internal_api_secret.php
//
// Device-control-plane milestone. Uwierzytelnia WYŁĄCZNIE
// POST /internal/mobile/device/validate — server-to-server, TA parafia
// do app.ministrant.eu. Celowo OSOBNY od config/ministrant_shared_secrets.php
// (MINISTRANT_INTERNAL_API_SECRET tam to jeden sekret WSPÓLNY dla całej
// floty parafii, dla innej relacji — parafia do ministrant.eu/brokera
// handoff). Ten sekret jest UNIKALNY DLA TEJ PARAFII: jeśli wycieknie,
// naraża tylko tę jedną parafię, nigdy całą flotę.
//
// ⚠ WARTOŚĆ PONIŻEJ TO PLACEHOLDER — przed wdrożeniem:
//   1. Wygeneruj prawdziwy sekret w panelu admina app.ministrant.eu dla
//      tej konkretnej parafii (Parish::mobile_internal_api_secret).
//   2. Wklej DOKŁADNIE tę samą wartość poniżej.
//   3. Nigdy nie commituj prawdziwej wartości do repozytorium/gita —
//      ten plik z placeholderem może zostać w repo, prawdziwy sekret
//      wgrywasz ręcznie na serwer, tak jak realne dane .env.

define('MOBILE_INTERNAL_API_SECRET', 'REPLACE_WITH_REAL_PER_PARISH_SECRET_FROM_ADMIN_PANEL');

// Adres app.ministrant.eu — bez końcowego slasha.
define('MOBILE_CENTRAL_BASE_URL', 'https://app.ministrant.eu');
