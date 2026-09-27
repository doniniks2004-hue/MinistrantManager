# Jak uruchomić CI (potrzebne, bo nie mam dostępu do Twojego GitHub)

Nie mam żadnych danych uwierzytelniających do Twojego konta/repozytorium
GitHub — nie jestem w stanie wypchnąć tego kodu ani uruchomić workflowów
z tej strony. Poniżej dokładne kroki, żeby zrobić to samodzielnie. Zajmie
to około 10 minut.

## 1. Rozpakuj cztery ZIP-y do jednego repozytorium

Struktura repo powinna wyglądać tak:

```
ministrant-manager/
├── backend/        ← zawartość MinistrantManager-Backend.zip
├── mobileapi/       ← zawartość MinistrantManager-MobileAPI.zip
├── mobile-android/  ← zawartość MinistrantManager-Android.zip
└── mobile-ios/      ← zawartość MinistrantManager-iOS.zip
```

(Android i iOS zip mają wspólny `/lib`, `/test` itd. — jeśli wolisz jedno
repo `mobile/` zamiast dwóch, scal ręcznie `android/` z jednego i `ios/`
z drugiego do wspólnego katalogu; workflowy w każdym zipie zakładają, że
uruchamiają się z katalogu głównego swojego pakietu).

## 2. Utwórz repozytorium i wypchnij

```bash
cd ministrant-manager
git init
git add .
git commit -m "Iteracja 1 — cztery paczki po trzeciej rundzie przeglądu"
git branch -M main
git remote add origin https://github.com/<TWOJA_NAZWA>/ministrant-manager.git
git push -u origin main
```

Ponieważ każdy pakiet ma **własny** katalog `.github/workflows/` (bo są
to cztery osobne paczki, nie jedno repo od początku), GitHub Actions
uruchomi **wszystkie pięć workflowów naraz** po pierwszym pushu, jeśli
umieścisz je w jednym repo jak wyżej (Actions skanuje `.github/workflows/`
w całym repo, niezależnie z jakiego "pakietu" pliki pochodzą — upewnij
się tylko, że nie masz dwóch plików o tej samej nazwie z różną
zawartością w różnych podkatalogach; jeśli tak, jeden nadpisze drugi przy
kopiowaniu — w naszym przypadku nazwy są unikalne: `backend-test.yml`,
`mobileapi-test.yml`, `flutter-test.yml`, `android-build.yml`,
`ios-build.yml`).

Jeśli wolisz cztery osobne repozytoria (po jednym na paczkę) zamiast
jednego — też zadziała, po prostu uruchom kroki 2 osobno dla każdego.

## 3. Obserwuj wyniki

GitHub → zakładka **Actions** w repo. Powinieneś zobaczyć pięć
uruchomień:

- `Backend tests` (backend-test.yml)
- `MobileAPI tests` (mobileapi-test.yml)
- `Flutter analyze + test` (flutter-test.yml)
- `Android build` (android-build.yml)
- `iOS build` (ios-build.yml)

## 4. Czego oczekiwać

- **MobileAPI tests** — powinno przejść od razu na zielono (to jedyny
  workflow, który nie zależy od niczego poza gołym PHP — dokładnie to,
  co uruchamiałem lokalnie w tym środowisku).
- **Backend tests** — po poprawkach tej rundy (API routing naprawiony w
  `ci/enable-api-routing.php`) powinno przejść, ale to pierwsze realne
  uruchomienie `composer create-project` + Twój pakiet razem — jeśli coś
  w Laravel 11 się zmieniło od mojej wiedzy, może wymagać drobnej
  korekty `ci/overlay-package.sh`.
- **Flutter analyze + test**, **Android build**, **iOS build** — to
  pierwsze uruchomienie na cokolwiek innym niż statyczna analiza tekstu
  z mojej strony. Realnie możliwe punkty tarcia:
  - dokładne wersje `drift`/`sqlite3`/`drift_dev` w `pubspec.yaml` mogą
    wymagać drobnej korekty względem tego, co faktycznie jest na pub.dev
    w dniu uruchomienia (zaznaczone w `docs/ENCRYPTION.md`),
  - `hooks.user_defines.sqlite3.source: sqlite3mc` — to pierwsza
    faktyczna próba zadziałania tego mechanizmu w tym projekcie.

## 5. Co zrobić, jeśli coś czerwone

Wklej mi log błędu z zakładki Actions (fragment ze stack trace/komunikatem
błędu wystarczy, nie cały log) — naprawię to w kolejnej turze, celując
wyłącznie w to jedno konkretne miejsce, bez rozszerzania zakresu.
