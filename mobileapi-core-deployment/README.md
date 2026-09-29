# mobileapi-core-deployment/

To jest **wersjonowane źródło finalnej paczki wdrożeniowej parafii**.

GitHub Actions:
1. sprawdza składnię wszystkich plików PHP w tym katalogu,
2. uruchamia niezależne testy MobileAPI,
3. buduje z całej zawartości `witosa-deployment.zip`,
4. publikuje ZIP jako artefakt workflow `MobileAPI tests`.

Nie składamy produkcyjnej paczki ręcznie z plików z różnych commitów.

## Zawartość

- `mobileapi-core/` — logika PHP instalowana poza `public_html/`,
- `public_html-additions/` — pięć stubów API, handoff i config template,
- `migrations/` — migracje 001–005,
- `scripts/preflight.php`,
- `scripts/apply_substitution_hotfix.php`,
- `scripts/create_test_account.php`,
- `scripts/cleanup_test_account.php`,
- `scripts/smoke_test.sh`,
- `docs/` — runbook, matryca modułów i opis architektury.

## Dlaczego osobny folder od mobileapi/

`mobileapi/` zawiera wcześniejszy, framework-free kontrakt/test harness
z Iteracji 1. Realne wdrożenie plain-PHP do istniejącej parafii jest
wersjonowane tutaj, ponieważ musi współpracować z jej istniejącym
`config/database.php`, sesjami i schematem legacy.

## Ważne

- prawdziwe sekrety parafii nie trafiają do repo,
- Android JKS/hasła nie trafiają do repo,
- paczka zawiera tylko placeholder config dla
  `MOBILE_INTERNAL_API_SECRET`,
- hotfix legacy odmawia nadpisania pliku, jeśli SHA-256 produkcji różni się
  od audytowanego baseline,
- finalne uruchomienie na Witosie odbywa się zgodnie z
  `docs/WITOSA-DEPLOYMENT.md`.

## Stan testów

CI pokrywa:
- syntax PHP,
- MobileAPI tests,
- budowę paczki deploymentowej,
- Flutter analyze/test,
- Android build,
- iOS build,
- backend centralny.

Realny test hostingu, PHP session/WebView, urządzeń i danych produkcyjnych
jest finalnym acceptance po brandingu — nie zastępujemy go zielonym CI.
