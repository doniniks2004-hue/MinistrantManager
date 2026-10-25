# Odbiór wydania Android / iOS — 25.10.2026

Gałąź: `release/android-ios-close`; Draft PR #50 do `main`.
Punkt odniesienia: PR #49, `8cc861c98fbd9e6311807ed33d8597cb21b56b6b`.
Kolejność integracji: `fixes-on-pr49.patch`, potem `fixes2-cumulative-1-12-on-pr49-base.patch`.
Sama nazwa drugiej łaty nie oznacza, że nakłada się ona na czysty PR #49.

## MacBook: przygotowanie i uruchomienie

Wymagane: Xcode wraz z runtime symulatora iPhone, Flutter 3.47.3, CocoaPods.
Najpierw uruchom Xcode i zakończ instalację wymaganych komponentów.

```bash
git clone --branch release/android-ios-close https://github.com/doniniks2004-hue/MinistrantManager.git
cd MinistrantManager
git rev-parse HEAD
flutter doctor -v
cd mobile-ios
flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs
dart run flutter_native_splash:create
cd ios
pod install
cd ..
open -a Simulator
flutter devices
```

Uruchom właściwą aplikację na identyfikatorze symulatora z `flutter devices`:

```bash
flutter run -d IDENTYFIKATOR_SYMULATORA
```

Zapisz SHA i wyniki. Po świeżej instalacji musi być widoczny ekran aktywacji, bez błędu
Keychain. Następnie sprawdź aktywację, logowanie i rzeczywisty panel parafii.
Nie usuwaj działającej instalacji z danymi użytkownika tylko po to, żeby uzyskać świeżą
instalację: użyj osobnego symulatora testowego.

## Osobny test mechanizmów natywnych

Na osobnym symulatorze można uruchomić:

```bash
flutter run -d IDENTYFIKATOR_SYMULATORA -t lib/selftest/main_selftest.dart
```

To osobna aplikacja testowa z tym samym bundle ID — nie jest paczką dla klientów.
Sprawdza szyfrowanie, zapis kopii, serwer lokalny i WebView na danych testowych.
Nie potwierdza logowania do produkcji ani zgodności prawdziwego panelu.

## Odbiór funkcjonalny właściwej aplikacji

- Świeża aktywacja i logowanie; otwarcie grafiku i innych dostępnych modułów.
- Otwarcie panelu online, zapis kompletnej kopii, restart aplikacji bez sieci.
- Pięć zimnych startów offline i dwadzieścia cykli online/offline/online.
- Powrót sieci przy otwartym panelu; brak ręcznego odświeżania i zbędnego logowania.
- Wylogowanie i inne konto: brak dostępu do kopii poprzedniego użytkownika.
- Cofnięcie dostępu i przywrócenie dostępu na dedykowanym urządzeniu testowym.
- Reset parafii i wznowienie przerwanego czyszczenia: brak otwarcia starych danych.
- iOS: powrót z tła, restart procesu, trwałość aktywacji i Keychain.

Testy cofnięcia dostępu/resetu wykonuj na instalacji testowej, nie na działającym
urządzeniu klienta. K12 jest dziś niedostępny; wyników z symulatora nie oznaczaj jako
wyników z K12 lub fizycznego iPhone'a. Czasy mierz osobno od uruchomienia procesu
i od otwarcia strony; nie zamieniaj jednego pomiaru na drugi.

## Paczki i podpisy

Artefakty muszą wskazywać dokładny SHA. Debug APK służy do testów. Release APK/AAB
podpisany tymczasowym kluczem CI nie jest wydaniem produkcyjnym ani aktualizacją
podpisaną kluczem właściciela. Symulator `.app` nie jest instalowalnym IPA na iPhone.

Do IPA/TestFlight wymagane są właściwe Apple Team ID, certyfikat, provisioning profile
i dostęp App Store Connect; szczegóły: `mobile-ios/docs/IOS-RELEASE-CHECKLIST.md`.
Certyfikatów, profili i haseł nie dodawaj do repozytorium. Bez podpisania i odbioru
urządzenia wynik oznacz jako build do testów, nie publikację w sklepie.

Scalenie do `main` i wdrożenie pozostają osobnym krokiem po odbiorze.
