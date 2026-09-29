# RELEASE-READINESS.md

Stan po finalnym domknięciu funkcjonalnym przed brandingiem i testem
akceptacyjnym na realnym urządzeniu.

## Gotowe w kodzie

| Element | Status |
|---|---|
| Nazwa aplikacji „Ministrant Manager” | ✅ |
| Android Application ID | ✅ `eu.ministrant.manager` |
| iOS Bundle ID | ✅ `eu.ministrant.manager` |
| Wersja startowa | ✅ `1.0.0+1` |
| INTERNET + CAMERA / opis kamery iOS | ✅ |
| 7/7 modułów native/offline | ✅ |
| Dynamiczny dashboard native/WebView | ✅ |
| WebView handoff + role + one-time ticket | ✅ |
| Device-control-plane app.ministrant.eu ↔ parafia | ✅ |
| Wymuszona pierwsza zmiana hasła | ✅ |
| Legacy substitutions hardening | ✅ instalator w paczce Witosy |
| Automatyczny ZIP wdrożeniowy Witosy w CI | ✅ |
| Android debug build / iOS unsigned build | ✅ |

## Branding — jedyny brakujący element UI

Czekamy na prawdziwe materiały marki:
- logo Ministrant Manager (preferowane SVG lub duży PNG z przezroczystym tłem),
- kwadratowy symbol/app icon (preferowane SVG/PNG 1024×1024 lub większy).

Z tych dwóch źródeł generujemy:
- `logo.png`,
- `app_icon.png`,
- `splash_logo.png`,
- komplet mipmap Android,
- komplet AppIcon iOS,
- finalny splash przez `flutter_native_splash`.

Do tego czasu w aplikacji nadal może być domyślna ikona Fluttera.

## Android release signing — klucz GOTOWY

Docelowy klucz release został wygenerowany i zweryfikowany.

- alias: `ministrant_manager_release`
- RSA 2048
- ważność: 2026-09-29 → 2054-02-14
- certificate SHA-256:
  `B0:48:52:A5:08:9D:AC:71:14:2F:56:C3:81:62:2A:BE:6B:75:DC:C8:CE:5C:2D:38:56:3F:E4:19:C2:D1:C7:4F`
- keystore SHA-256:
  `a145c7fd5e3ad244eec6d5355ddc96d5ea5fa1e55d716863bf3296386769a2a3`

Zaszyfrowany, testowo odtworzony backup jest poza repo, w prywatnej
Bibliotece użytkownika:
`/MinistrantManager/Secrets/android-signing-backup.tar.enc`.

Repo **nie zawiera** JKS ani haseł.

### Jedyny ręczny krok GitHub

Obecne narzędzia nie pozwalają bezpośrednio zapisywać GitHub Actions
Secrets. Trzeba jednorazowo ustawić cztery sekrety repo:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Workflow:
- działa normalnie w trybie debug, gdy nie ma żadnego sekretu,
- odmawia pracy przy częściowo ustawionym komplecie,
- po ustawieniu wszystkich czterech buduje podpisany release APK i AAB.

Hasła/klucz nigdy nie mogą zostać wpisane do pliku w repo.

## iOS release signing

Kod i workflow są przygotowane, ale podpisanie IPA/TestFlight wymaga
zewnętrznych danych Apple:
- aktywne Apple Developer Program,
- Team ID,
- Distribution Certificate,
- provisioning profile.

To nie blokuje funkcjonalnego ukończenia aplikacji; blokuje wyłącznie
podpisaną dystrybucję iOS/TestFlight/App Store.

## Wdrożenie Witosy

CI buduje artefakt `witosa-deployment.zip`, zawierający:
- MobileAPI,
- migracje 001–005,
- pięć publicznych stubów API,
- WebView handoff,
- flow pierwszej zmiany hasła,
- konfigurację device-control-plane,
- `scripts/apply_substitution_hotfix.php`,
- preflight/smoke/cleanup,
- aktualną instrukcję wdrożenia.

Hotfix zamian jest fail-closed:
- sprawdza SHA-256 audytowanego legacy,
- robi backup,
- podmienia pliki atomowo,
- sprawdza końcowe SHA-256,
- rollbackuje przy błędzie,
- drugie uruchomienie jest bezpiecznym no-op.

## Co oznacza „gotowe”

**Funkcjonalnie:** po przejściu aktualnego CI i dodaniu brandingu kod jest
zamknięty do finalnej rundy acceptance/hardening.

**Do publikacji sklepów:** dodatkowo wymagane są:
1. branding,
2. ustawienie 4 sekretów Androida,
3. Apple Developer + signing dla iOS,
4. finalny test realnego urządzenia/Witosy,
5. upload do Google Play Console / App Store Connect.

Publikacja do sklepów jest celowo dopiero po pełnym teście akceptacyjnym.
