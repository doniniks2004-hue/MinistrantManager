# Test na iPhonie z MacBooka

To przygotowanie do lokalnego podpisania kontem właściciela. Paczka źródeł nie jest instalowalnym IPA. Nie podawaj hasła Apple w czacie ani w plikach projektu.

## Przygotuj MacBooka wcześniej

- Xcode z obsługą wersji iOS na Twoim iPhonie; otwórz go i dokończ instalację komponentów iOS.
- Flutter **3.47.3** i CocoaPods dostępne w Terminalu. Instrukcja: https://docs.flutter.dev/platform-integration/ios/setup
- Konto Apple dodane w Xcode → Settings → Accounts.
- iPhone podłączony kablem, odblokowany, z zaakceptowanym zaufaniem do MacBooka. Gdy Xcode poprosi, włącz Tryb deweloperski na iPhonie.

## Przygotowanie projektu

Rozpakuj źródła repozytorium. W Terminalu przejdź do katalogu `mobile-ios` z rozpakowanej paczki i uruchom:

```bash
bash tools/prepare-mac-test.command
```

Skrypt sprawdza narzędzia, pobiera zależności z lockfile, generuje kod i konfigurację, instaluje pody i otwiera `ios/Runner.xcworkspace`. Nie wybiera konta Apple i nie podpisuje aplikacji bez Twojego udziału.

W Xcode wybierz projekt Runner, następnie **TARGETS → Runner → Signing & Capabilities**. Włącz **Automatically manage signing** i wybierz swój **Team**. Wybierz fizycznego iPhone'a jako urządzenie i naciśnij **Run**. To jest lokalna instalacja deweloperska, a nie TestFlight.

## Jeżeli masz tylko bezpłatny Personal Team

W tej lokalnej kopii testowej:

1. Ustaw unikalny Bundle Identifier, np. `pl.twojnick.ministranttest`.
2. Usuń capability **Associated Domains** w Signing & Capabilities (przycisk minus/kosz przy capability), jeśli Xcode odrzuca ją dla Twojego konta. Nie usuwaj innych ustawień prywatności ani zabezpieczeń sieci.
3. Ponownie wybierz Personal Team i uruchom aplikację na podłączonym telefonie.

Tak przygotowana kopia służy do testów przez QR/ręczną aktywację; nie potwierdza Universal Links. Nie wysyłaj tych lokalnych zmian identyfikatora/capability do gałęzi wydania. Profile Personal Team wygasają po 7 dniach — wtedy trzeba ponownie zbudować i zainstalować aplikację.

## Co sprawdzić

- Świeża aktywacja QR i logowanie kontem testowym.
- Wymuszona zmiana hasła, jeśli konto jej wymaga.
- Przełączenie offline/online, zapisane strony i powrót z tła.
- Wylogowanie i drugie konto: brak danych poprzedniej osoby.
- Aparat/QR, otwieranie dokumentów oraz pomiar czasu uruchomienia.

Nie wykorzystuj pomiarów builda debug jako ostatecznego pomiaru wydania release. TestFlight i dystrybucja IPA wymagają osobnego podpisania i odpowiedniego profilu Apple.

Źródła:
- https://developer.apple.com/help/account/basics/about-your-developer-account/
- https://help.apple.com/xcode/mac/current/en.lproj/dev23aab79b4.html
- https://docs.flutter.dev/deployment/ios
