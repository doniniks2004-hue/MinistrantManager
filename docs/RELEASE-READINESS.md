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
| Legacy maintenance/admin hardening | ✅ updater/receiver/fix/reset disabled + settings CSRF |
| Legacy web/session hardening | ✅ same-origin guard + empty.php CSRF + upload hardening |
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
- zawsze buduje debug APK,
- bez produkcyjnych sekretów generuje wyłącznie na runnerze tymczasowy
  keystore, buduje release AAB z minifikacją i natychmiast usuwa ten AAB
  oraz tymczasowy klucz — dzięki temu release path jest testowany w CI,
- odmawia pracy przy częściowo ustawionym komplecie sekretów,
- przy 4/4 sekretach dekoduje prawdziwy JKS do `android/release.keystore`,
  weryfikuje hasło magazynu i alias przez `keytool`,
- następnie buduje podpisany release APK i AAB.

Hasła/klucz nigdy nie mogą zostać wpisane do pliku w repo.

## iOS release signing

Kod i workflow są przygotowane. Podpisane IPA/TestFlight wymaga czterech
sekretów repo:

- `APPLE_CERTIFICATE_BASE64` — certyfikat Apple Distribution w formacie P12, base64,
- `APPLE_CERTIFICATE_PASSWORD`,
- `APPLE_PROVISIONING_PROFILE_BASE64` — profil App Store dla `eu.ministrant.manager`, base64,
- `APPLE_TEAM_ID`.

Workflow jest fail-closed:
- bez żadnego sekretu buduje unsigned simulator build,
- częściowy komplet 1–3/4 sekretów kończy job błędem konfiguracji,
- przy 4/4 dekoduje P12 i provisioning profile na runnerze,
- sprawdza Team ID i Bundle ID profilu,
- generuje tymczasowe `Signing.xcconfig` i `ExportOptions.generated.plist`,
- buduje podpisane IPA.

Repo nie zawiera certyfikatu, profilu, Team ID ani haseł. Aktywne Apple
Developer Program pozostaje zewnętrznym warunkiem dystrybucji iOS.

## Wdrożenie Witosy

CI buduje artefakt `witosa-deployment.zip`, zawierający:
- MobileAPI,
- migracje 001–005,
- pięć publicznych stubów API,
- WebView handoff,
- flow pierwszej zmiany hasła,
- konfigurację device-control-plane,
- `scripts/apply_legacy_security_hardening.php`,
- `scripts/apply_legacy_web_hardening.php`,
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
