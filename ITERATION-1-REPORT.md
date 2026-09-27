# Ministrant Manager — Raport Iteracji 1 (ZAMKNIĘTA — 5/5 GitHub Actions GREEN)

**Status: Iteracja 1 zamknięta.** Wszystkie pięć workflowów CI przechodzi
na commitcie `407e5c3` (i późniejszych) w repo
`github.com/doniniks2004-hue/MinistrantManager`:

| Workflow | Status |
|---|---|
| Backend tests | ✅ GREEN |
| MobileAPI tests | ✅ GREEN |
| Flutter analyze + test | ✅ GREEN (9 plików testowych faktycznie wykonanych) |
| Android build (`flutter build apk --debug`) | ✅ GREEN |
| iOS build (`flutter build ios --simulator --no-codesign`) | ✅ GREEN |

To pierwszy moment, w którym możemy powiedzieć: **kod faktycznie się
kompiluje i przechodzi testy na prawdziwej infrastrukturze CI**, nie tylko
lokalnie na sucho.

---

## ZROBIONE (skumulowane, wszystkie rundy przeglądu)

Backend, MobileAPI i Flutter/Android/iOS przeszły łącznie cztery rundy
przeglądu kodu + jedną rundę realnego debugowania CI. Kluczowe punkty:

**Backend (app.ministrant.eu)**: role SUPER_ADMIN/ADMIN, recovery codes
(Argon2id, atomowe zużycie, kolumna `code_hash` poprawiona na 255 znaków),
rate limiting TOTP, `totp_secret` szyfrowany, panel Audit Log, naprawiona
aktywacja (transakcja + `lockForUpdate`), `DeviceStatusEvaluator`
(platforma-specyficzna wersja minimalna), `AppConfig::$table` naprawione,
`/device/status` przyjmuje i zapisuje `app_version`/`os_version` przed
oceną statusu, audit log/rate limiter używają fingerprintu (SHA-256) —
nigdy surowego kodu aktywacyjnego.

**MobileAPI**: `ActionDispatcher` z atomowym `tryClaim`/`finalize`/
`failClaim`, `ActionResult::fromCached()` wiernie odtwarzający oryginalny
status (error/conflict/applied — nigdy fałszywie `already_applied`),
`SyncService` z prawdziwym `hasMore` i tombstones, `VerifyDeviceTokenService`
z izolacją tenantów (test §36 dosłownie).

**Android/iOS (Flutter)**: `CipherEngine`/`MultiCiphersEngine` (SQLite3MultipleCiphers,
poprawny import `package:sqlite3/common.dart`), crypto-erase przy revoke,
`PreflightGate` (globalny client-config przed Activation/Home, z
działającym przyciskiem AKTUALIZUJ przez wspólny `StoreLinkLauncher`),
`DeepLinkService` z walidacją hosta, `checkDeviceStatus()` rozróżniający
transport failure / 401 / 403 / 5xx (nowy `DeviceAuthState.authError`,
fail-closed zamiast fail-open), kompletny natywny scaffold Android
(Kotlin DSL, AGP 9.1.0, Gradle 9.3.1) i iOS (Xcode project, bundle
identifier i deployment target 15.0 spójne wszędzie) — **wygenerowany
raz przez Flutter 3.47.3 i faktycznie zweryfikowany w CI**, nie
regenerowany przed każdym buildem.

## PRZETESTOWANE REALNIE (lokalnie, w tym środowisku)

Bez zmian względem poprzednich rund: testy współbieżności na
prawdziwych dwóch procesach OS (aktywacja, recovery code, MobileAPI
action claim), pełen zestaw testów framework-free MobileAPI, `php -l`
na 61 plikach backendu — 0 błędów.

## PRZETESTOWANE W CI — TERAZ RZECZYWIŚCIE ZIELONE

To jest fundamentalna zmiana względem poprzednich rund tego raportu,
gdzie ta sekcja mówiła "nic". Diagnozowanie i naprawa oparte były na
**prawdziwych logach GitHub Actions** (odczytywanych przez API, gdzie się
dało, lub dostarczanych bezpośrednio przez Ciebie, gdzie moja sieć nie
sięgała do Azure Blob Storage przechowującego pełne logi):

- Naprawione po drodze: kontekst `secrets` niedozwolony w `if:` (realne
  ograniczenie GitHub, nie fałszywy alarm), blokada advisory Composera
  (`policy.advisories.block` — projektowy, nie globalny config),
  niekompatybilna wersja Fluttera z Dart SDK wymaganym przez Drift
  ^2.32.0 (3.24.0→3.47.3), domyślny `ExampleTest.php` świeżego Laravela
  kolidujący z naszym routingiem, `CommonDatabase` w złym pakiecie
  (`sqlite3.dart`→`common.dart`), literówki Dart (brakujące nawiasy,
  `Value()`, `skip: true` zamiast stringa), podwójny `primaryKey` w
  Drift, przestarzała wersja AGP (8.3.2→9.1.0 przez pełną migrację na
  Kotlin DSL), niespójny bundle identifier iOS, deployment target 13.0→15.0.

## IMPLEMENTED / NOT VERIFIED ON REAL DEVICE

**Szyfrowanie lokalnej bazy — częściowy postęp.** Punkt 1 z
czteropunktowej checklisty (`docs/ENCRYPTION.md`) jest teraz
**potwierdzony**: `flutter pub get` i `flutter build apk`/`flutter build
ios` przechodzą realnie w CI z konfiguracją `hooks.user_defines.sqlite3.source:
sqlite3mc` — mechanizm faktycznie się rozwiązuje i aplikacja faktycznie
się kompiluje z nim. **Punkty 2-4 (otwarcie z poprawnym kluczem, odrzucenie
złego klucza, round-trip crypto-erase) nadal wymagają uruchomienia na
prawdziwym urządzeniu/emulatorze** — CI buduje, ale nie uruchamia
aplikacji ani nie wykonuje runtime asercji na cipherze.

## BLOCKERY

- Brak realnego keystore Android / konta Apple Developer → sekrety
  (`ANDROID_KEYSTORE_*`, `APPLE_CERTIFICATE_*`, `APPLE_TEAM_ID`) nie są
  ustawione w repo, więc release-signing kroki CI pozostają no-op
  (debug/simulator build wystarcza na tę iterację)
- Brak dostępu do istniejącego kodu/schematu Ministrant Manager →
  Iteracja 2

## PLACEHOLDERY (bez zmian)

`public/.well-known/*`, `ios/ExportOptions.plist` teamID,
`assets/branding/`, `ConfigController` (MobileAPI) zwraca pusty config.

## WYMAGA INTEGRACJI Z ISTNIEJĄCYM MM / DO ITERACJI 2

Bez zmian względem poprzednich rund: prawdziwe adaptery repozytoriów
domenowych, realne dane biznesowe (grafik/obecności/punkty/ranking/
ogłoszenia/zastępstwa), faktyczne `permissions`, integracja
`VerifyDeviceToken` z prawdziwym źródłem prawdy o urządzeniach. Każdy
handler non-versioned musi być idempotentny względem `client_action_id`
LUB objęty jedną transakcją z action logiem (udokumentowane w
`mobileapi/docs/INTEGRATION.md`).

---

**Iteracja 1 jest zamknięta.** Repozytorium
`github.com/doniniks2004-hue/MinistrantManager` zawiera pełną,
zweryfikowaną w CI historię — jeśli potrzebna jest analiza konkretnej
decyzji, jest ona opisana w odpowiadającym jej commicie. Gotowi do
Iteracji 2 z prawdziwym backendem Ministrant Manager.
