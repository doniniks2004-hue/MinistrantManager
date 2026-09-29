# RELEASE-READINESS.md

## Gotowe już dziś

| Element | Status | Gdzie |
|---|---|---|
| Nazwa aplikacji | ✅ „Ministrant Manager" | `AndroidManifest.xml`, `Info.plist` |
| Application ID / Bundle ID | ✅ `eu.ministrant.manager` (oba) | `build.gradle.kts`, `project.pbxproj` |
| Numer wersji | ✅ `1.0.0+1` | `pubspec.yaml` |
| Uprawnienia | ✅ INTERNET, CAMERA (skaner QR) + opis użycia kamery na iOS | `AndroidManifest.xml`, `Info.plist` |
| Ikona aplikacji | 🔶 domyślna ikona Fluttera (wszystkie gęstości obecne, ale nie logo Ministrant Manager) | `android/.../mipmap-*`, `ios/.../AppIcon.appiconset` |
| Infrastruktura AAB (Android) | ✅ `flutter build appbundle` w CI, warunkowe na realnym keystore | `.github/workflows/android-build.yml` |
| Infrastruktura podpisanego IPA (iOS) | ✅ `flutter build ipa`, warunkowe na realnym certyfikacie | `.github/workflows/ios-build.yml` |
| CI 5/5 | ✅ | patrz ostatni commit |

## Zablokowane — wymaga danych od Ciebie, nie da się tego zrobić za Ciebie

### 1. Prawdziwe logo/ikona/splash

Folder `assets/branding/` **już istnieje i czeka** (`README.txt` w
środku, prawdopodobnie z wcześniejszej rundy) na:
- `logo.png` — pełne poziome logo
- `app_icon.png` — kwadratowy symbol graficzny (nie pomniejszone logo)
- `splash_logo.png` — logo na ekran powitalny

**Świadomie nie odtworzyłem tych plików ręcznie** — to prawdziwy znak
firmowy Ministrant Managera, nie coś, co powinienem zgadywać/rysować.
Podeślij oryginalne pliki źródłowe (SVG/AI/wysokiej rozdzielczości PNG),
a dokończę generowanie ikon dla wszystkich gęstości Android + iOS i
konfigurację splash screena (`flutter_native_splash`, już dodany jako
zależność — patrz niżej).

### 2. Prawdziwe sekrety podpisywania (Android)

CI ma już gotową, warunkową ścieżkę — potrzebuje w **Settings → Secrets
and variables → Actions** tego repo:
- `ANDROID_KEYSTORE_BASE64` — Twój release keystore (`.jks`), zakodowany
  `base64 -w0 twoj-plik.jks`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

**Nie mogę i nie powinienem generować tego keystore'a za Ciebie** — to
prywatny klucz, który MUSISZ wygenerować i przechowywać samodzielnie
(`keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048
-validity 10000 -alias <alias>`). Zgubienie go = utrata możliwości
aktualizacji aplikacji w Google Play pod tym samym ID.

### 3. Prawdziwe sekrety podpisywania (iOS / TestFlight)

Analogicznie, w tych samych ustawieniach repo:
- `APPLE_TEAM_ID`
- certyfikat dystrybucyjny + provisioning profile (dokładne nazwy
  sekretów w `.github/workflows/ios-build.yml`)

Wymaga aktywnego konta Apple Developer Program — to też coś, co musi
istnieć po Twojej/firmy stronie.

## Co zrobiłem w tej rundzie

- `flutter_native_splash` dodany jako zależność deweloperska + wpis
  konfiguracyjny w `pubspec.yaml`, wskazujący na
  `assets/branding/splash_logo.png` — **nieaktywny, dopóki ten plik nie
  istnieje** (polecenie generujące splash po prostu nic nie zrobi/da
  błąd braku pliku, dopóki go nie podeślesz — to zamierzone, nie bug).

## Kiedy będzie można faktycznie opublikować

1. Podeślij 3 pliki logo → dokończę ikony + splash w jednej rundzie.
2. Wygeneruj i dodaj sekrety Android + iOS w ustawieniach repo → następny
   push automatycznie zacznie produkować podpisane artefakty (AAB + IPA)
   zamiast tylko debug APK.
3. Dopiero wtedy realny upload do Google Play Console / App Store
   Connect — to już świadomie poza zakresem tego etapu (release
   readiness ≠ publikacja).
