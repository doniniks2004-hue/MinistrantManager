# Ministrant Manager — aplikacja mobilna (Flutter)

Wspólny kod źródłowy (`/lib`) dla Androida i iOS: offline-first, Drift +
SQLite (zaszyfrowane przez SQLite3MultipleCiphers), klucz
szyfrujący w Keystore/Keychain (`flutter_secure_storage`), aktywacja przez
QR/kod/App Links/Universal Links przez `app.ministrant.eu`, dane
biznesowe z subdomeny właściwej parafii (`{slug}.ministrant.eu/api/v1/...`),
dynamiczny dashboard server-driven (spec §15–§19), globalny client-config
(store URLs, tryb konserwacji, wymuszona aktualizacja).

## Wersje — WERYFIKUJ przed budową

Flutter i wszystkie zależności w `pubspec.yaml` zostały przypięte na
podstawie wiedzy z okresu tworzenia tego archiwum — to środowisko nie miało
dostępu do `pub.dev` do ich weryfikacji na żywo (sieć ograniczona do
npm/PyPI/crates.io/GitHub/Ubuntu archives). Przed pierwszym
`flutter pub get` sprawdź, czy wersje w `pubspec.yaml` (zwłaszcza
`drift`/`sqlite3`/`hooks.user_defines`, `app_links`, `mobile_scanner`) nadal istnieją i
czy nie ma nowszych patchy bezpieczeństwa.

## Czego NIE ma w tym archiwum i dlaczego

Nie dołączono binarnego `gradle-wrapper.jar` ani wygenerowanego projektu
Xcode (`Runner.xcodeproj/project.pbxproj`) — to pliki generowane
automatycznie przez `flutter create`, nie pisane ręcznie (jeśli Wasze
środowisko developerskie ma Flutter SDK, wygenerowanie ich jest
natychmiastowe i deterministyczne — nie ma sensu ręcznie je odtwarzać).

**Przed pierwszym build (Android LUB iOS — CI robi to automatycznie, patrz
`.github/workflows/`):**

```bash
flutter create --org eu.ministrant --project-name ministrant_manager .
```

Odpowiedz "n" na nadpisanie: `android/app/build.gradle`,
`android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`,
`ios/Runner/Runner.entitlements`, `ios/Podfile` — te already zawierają
konfigurację specyficzną dla tego projektu (App Links/Universal Links,
uprawnienia kamery, itd.).

## Instalacja

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # generuje app_database.g.dart (Drift)
```

## Build — Android

```bash
flutter build apk --release      # app-release.apk
flutter build appbundle --release # app-release.aab
```

## Build — iOS

```bash
cd ios && pod install && cd ..
flutter build ios --release
# lub, z dostępem do certyfikatu Apple Developer:
flutter build ipa --export-options-plist=ios/ExportOptions.plist
```

## CI (GitHub Actions)

- `.github/workflows/flutter-test.yml` — `flutter analyze` + `flutter test`, na każdy push/PR
- `.github/workflows/android-build.yml` — zawsze buduje debug APK; buduje podpisany release APK/AAB TYLKO gdy sekrety `ANDROID_KEYSTORE_BASE64`/`ANDROID_KEYSTORE_PASSWORD`/`ANDROID_KEY_PASSWORD`/`ANDROID_KEY_ALIAS` są ustawione w repo
- `.github/workflows/ios-build.yml` — zawsze buduje unsigned build na symulator (macOS runner); buduje podpisany IPA TYLKO gdy sekrety `APPLE_CERTIFICATE_BASE64`/`APPLE_CERTIFICATE_PASSWORD`/`APPLE_PROVISIONING_PROFILE_BASE64`/`APPLE_TEAM_ID` są ustawione

**Żaden z tych workflow'ów nie został uruchomiony w tym środowisku** — nie ma tu
Actions runnera. Napisane poprawnie wg dokumentacji `subosito/flutter-action`,
ale pierwszy prawdziwy przebieg po wypchnięciu do GitHub jest tym, co
faktycznie to zweryfikuje.

## Struktura

```
lib/
  core/
    database/       — schemat Drift (tabele + migracje, schemaVersion), zaszyfrowany SQLCipher
    secure/          — SecureStorageService (Keystore/Keychain — device_token, installation_id, server_url, klucz DB)
    network/         — ApiClient (rozdziela app.ministrant.eu od {parafia}.ministrant.eu)
    sync/            — SyncEngine (bootstrap/sync/actions, dynamiczny offline lease, konflikty 409, tombstones)
    deeplink/        — DeepLinkService (Android App Links / iOS Universal Links → ekran aktywacji)
  features/
    activation/      — skan QR + kod ręczny + deep link, ekran potwierdzenia
    config/          — ConfigService (fetch+cache client-config globalny ORAZ dashboard config per-parafia)
    dashboard/       — DashboardScreen (server-driven moduły, native/WebView, role i bezpieczny fallback)
    home/            — ekran główny: baner OFFLINE, tryb konserwacji, wymuszona aktualizacja z linkiem do sklepu, dashboard
    revocation/       — obsługa DEVICE_REVOKED / PARISH_DISABLED (czyszczenie danych)
```

## Szyfrowanie lokalnej bazy (spec §21/§25, decyzja #4) — status: `IMPLEMENTED / NOT VERIFIED ON REAL DEVICE`

`AppDatabase` otwiera SQLite przez SQLite3MultipleCiphers (build SQLite
z wbudowanym cipherem `chacha20`, wybierany przez wpis `hooks.user_defines.sqlite3.source: sqlite3mc`
w `pubspec.yaml` — patrz `docs/ENCRYPTION.md`) i klucz `PRAGMA key = '...'` pochodzący z
`SecureStorageService.getOrCreateDbEncryptionKey()` — generowany raz,
losowo (`Random.secure()`, 256-bit), zapisany WYŁĄCZNIE w Keystore/Keychain.
Baza nie otwiera się bez tego klucza.

## Stan integracji modułów

- Siedem modułów P1 ma natywne ekrany: Mój grafik, Ogłoszenia, Punkty,
  Ranking, Zastępstwa, Obecności i Profil.
- `DashboardScreen` nawiguje do ekranów natywnych albo do bezpiecznego
  WebView zgodnie z konfiguracją serwera; role są filtrowane w UI i
  niezależnie egzekwowane po stronie serwera.
- `SyncEngine` zapisuje snapshot i zmiany do Drift/SQLite, a ekrany
  biznesowe czytają dane lokalnie, dlatego pozostają użyteczne offline
  w ramach ważnego offline lease.
- Lista modułów jest server-driven i może zmieniać dostępność/native vs
  WebView bez wydawania nowej aplikacji, o ile bieżąca wersja klienta
  obsługuje wskazany ekran/kontrakt.

## Test obowiązkowy przed oddaniem (spec §37–§45) — status

**NIEPRZETESTOWANE Z POWODU ŚRODOWISKA** — brak tu fizycznego/emulowanego
telefonu i brak wdrożonego `app.ministrant.eu`/parafii. Żaden z poniższych
punktów nie został fizycznie wykonany:

1. Aktywacja CHWK (QR, Android) → poprawna subdomena
2. To samo na iOS
3. Tryb samolotowy + kill aplikacji + restart → dane nadal są
4. Restart telefonu, offline → dane nadal są
5. Akcja offline → pending → restart aplikacji → akcja nadal w kolejce
6. Wi-Fi ON → pending action wykonana dokładnie raz
7. Dezaktywacja urządzenia z panelu → przy kolejnym połączeniu: DEVICE_REVOKED, dane skasowane
8. Dezaktywacja całej parafii → wszystkie urządzenia tracą dostęp, inne parafie działają normalnie
9. QR innej parafii nigdy nie pobiera danych złej subdomeny (logika TENANT_MISMATCH jest przetestowana po stronie serwera — patrz MobileAPI package — ale end-to-end przez prawdziwy telefon nie)
10. Kod wygasły/unieważniony/błędny → aktywacja odrzucona
11. Migracja: stara wersja + dane offline + pending action → aktualizacja → dane nadal poprawne
12. Dynamiczny dashboard/moduł zmienia się bez nowego APK/IPA

Do wykonania ręcznie lub jako `integration_test/` (pakiet `integration_test`
z Flutter SDK) na prawdziwym urządzeniu/emulatorze, przeciwko realnie
wdrożonym: `app.ministrant.eu` + co najmniej jednej parafii z
`MinistrantManager-MobileAPI` zainstalowanym.
