# Ministrant Manager — Raport Iteracji 1 (po trzech rundach przeglądu 1.1)

Ten raport zamyka Iterację 1 w zakresie, który mogłem faktycznie wykonać
bez dostępu do Twojego repozytorium GitHub. Cztery deliverable'y:

- `MinistrantManager-Backend.zip` — app.ministrant.eu
- `MinistrantManager-MobileAPI.zip` — kontrakt + silnik sync/actions
- `MinistrantManager-Android.zip` / `MinistrantManager-iOS.zip` — Flutter
- `RUNNING-CI.md` — dokładna instrukcja uruchomienia CI (punkt 8 przeglądu)

---

## ZROBIONE — zmiany tej (trzeciej) rundy

1. **Konfiguracja SQLite3MultipleCiphers naprawiona** — usunięty błędny
   `sqlite3mc: ^1.0.0` jako osobna zależność; poprawna konfiguracja to
   `hooks.user_defines.sqlite3.source: sqlite3mc` w `pubspec.yaml`.
   `drift`/`drift_dev` podniesione do `^2.32.0` (kompatybilne z `sqlite3`
   3.x — Drift 2.21 tego nie obsługiwał). Usunięte wszystkie odniesienia
   do `hooks/build.dart` i pakietu `sqlite3mc` z dokumentacji.
2. **Wersja Flutter ujednolicona** — wszystkie trzy workflowy (`flutter-test`,
   `android-build`, `ios-build`) przypięte na `3.27.0` (Dart 3.6.0),
   zgodnie z `pubspec.yaml`'s `sdk: '>=3.6.0'`. Poprzednie `3.24.0`
   (Dart 3.5.x) faktycznie zawaliłoby `flutter pub get`.
3. **API routing w CI naprawiony** — nowy `ci/enable-api-routing.php`
   wstrzykuje `api: __DIR__.'/../routes/api.php'` do `withRouting()` w
   świeżo wygenerowanym `bootstrap/app.php` (Laravel 11 nie rejestruje
   API routes domyślnie). Przetestowany end-to-end lokalnie na
   realistycznym szkielecie — działa poprawnie i idempotentnie.
4. **Błąd replay `error`→`already_applied` naprawiony** — dodana
   `ActionResult::fromCached()`, która odtwarza ORYGINALNY status
   (`error`/`conflict`/`applied`) zamiast zawsze zwracać
   `already_applied`. **Zweryfikowałem realnie dokładnie ten scenariusz z
   Twojego zgłoszenia** i potwierdzam, że przed poprawką occurred exactly
   as reported; po poprawce naprawione i pokryte dwoma nowymi grupami
   testów (terminal error replay + conflict replay).
5. **Granice gwarancji exactly-once doprecyzowane w dokumentacji** —
   `ActionLogRepositoryInterface` i `docs/INTEGRATION.md` teraz jawnie
   mówią: `tryClaim()` chroni przed współbieżnym podwójnym wykonaniem,
   ale NIE przed sekwencyjnym re-claimem po awarii między mutacją a
   `finalize()`. Realny handler non-versioned w Iteracji 2 musi być albo
   idempotentny względem `client_action_id`, albo claim+mutacja+finalize
   muszą być w jednej transakcji DB.

Punkty 6 (crypto-erase) i 7 (PreflightGate/DeepLinkService) z poprzedniej
rundy potwierdzone jako OK — nieprzebudowywane.

## PRZETESTOWANE REALNIE

Wszystko z poprzednich rund ponownie uruchomione (61 plików backendu,
46 MobileAPI — 0 błędów `php -l`). Nowe testy tej rundy:

| Test | Co dowodzi | Wynik |
|---|---|---|
| `ActionDispatcherTest.php` — grupa 5 | **Dosłowny scenariusz z Twojego zgłoszenia**: unknown action → `error` → retry tego samego `client_action_id` → nadal `error`, NIE `already_applied`, ten sam `reason` co za pierwszym razem, stabilne przy trzeciej próbie | PASS |
| `ActionDispatcherTest.php` — grupa 6 | Replayowany `conflict` pozostaje `conflict` (nie `already_applied`), z poprawnym `current_record` | PASS |
| `ci/enable-api-routing.php` (test lokalny) | Wstrzykuje `api:` do realistycznego szkieletu `bootstrap/app.php`, idempotentnie (drugie uruchomienie = no-op) | PASS |

## PRZETESTOWANE W CI

**Nadal nic.** Bez zmian względem poprzedniej rundy — nie mam dostępu do
Twojego repozytorium GitHub. **Patrz `RUNNING-CI.md`** — dokładna,
krok-po-kroku instrukcja przygotowana specjalnie w tej rundzie (punkt 8
przeglądu), żebyś mógł to uruchomić samodzielnie. Dopóki nie zobaczymy
wyniku, status całej sekcji "CI" pozostaje deklaratywny, nie
zweryfikowany.

## IMPLEMENTED / NOT VERIFIED ON REAL DEVICE

Bez zmian statusu: szyfrowanie lokalnej bazy (SQLite3MultipleCiphers).
Konfiguracja w `pubspec.yaml` poprawiona na właściwy mechanizm
(`hooks.user_defines`), ale nadal nie przeszła przez realny
`flutter pub get`/build — to właśnie pierwsze uruchomienie CI (patrz
wyżej) da na to odpowiedź.

## NIEPRZETESTOWANE Z POWODU ŚRODOWISKA

- Wszystkie testy na prawdziwym telefonie/emulatorze
- Wszystkie 9 plików `mobile/test/*.dart`
- Realny build APK/AAB/IPA
- Wdrożenie `app.ministrant.eu` na produkcję
- Wszystkie 5 workflow'ów CI — do czasu wykonania kroków z `RUNNING-CI.md`

## BLOCKERY

- **Brak dostępu do GitHub tego projektu** — patrz `RUNNING-CI.md` dla instrukcji, jak Ty możesz to odblokować
- **Packagist zablokowany w sieci tego środowiska**
- **Brak toolchaina Flutter/Android/iOS oraz brak dostępu do pub.dev**
- **Brak dostępu do istniejącego kodu/schematu Ministrant Manager**
- Brak finalnego keystore Android / konta Apple Developer

## PLACEHOLDERY

Bez zmian: App Links/Universal Links, `ExportOptions.plist` teamID,
`assets/branding/`, `ConfigController` (MobileAPI).

## WYMAGA INTEGRACJI Z ISTNIEJĄCYM MM

Bez zmian, plus nowy wymóg jawnie udokumentowany w `docs/INTEGRATION.md`:
każdy realny handler non-versioned (attendance/points/substitutions) musi
być albo idempotentny względem `client_action_id`, albo objęty jedną
transakcją z action logiem — patrz punkt 5 wyżej.

## DO ITERACJI 2

Bez zmian.

---

**Warunek zamknięcia Iteracji 1 pozostaje taki, jak ustaliliśmy**: dopiero
zielone CI (`flutter pub get`, `flutter analyze`, `flutter test`, Android
debug build, iOS simulator build, backend feature tests, MobileAPI tests)
pozwala nazwać ją COMPLETE. Z mojej strony kod jest gotowy do tej próby —
`RUNNING-CI.md` mówi dokładnie, jak ją wykonać.
