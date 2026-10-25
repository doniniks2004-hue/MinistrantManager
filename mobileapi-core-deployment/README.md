# Universal Parish Installer

Ten katalog jest źródłem **jednego instalatora dla wszystkich parafii**.
Nie tworzymy osobnego ZIP-a dla każdej parafii.

GitHub Actions buduje artefakt:

`universal-parish-installer.zip`

## Model skalowania

Instalator składa się z:
- wspólnego silnika `install.php`,
- wspólnego MobileAPI,
- profili zgodności w `profiles/`,
- adapterów legacy w `mobileapi-core/ParishAdapters/`,
- wspólnych migracji, hardeningu, smoke testów i rollbacku.

Parafia nie ma własnego ZIP-a. Jeżeli dwie parafie używają tego samego
wariantu legacy, korzystają z tego samego profilu/adaptera.

Pierwszym profilem jest:
- `Witosa` — audytowany wariant obecnego legacy Ministrant Manager.

Kolejne warianty dodaje się jako nowy profil/adaptor do TEJ SAMEJ paczki.

## Instalacja przez przeglądarkę

Przy samym menedżerze plików użyj [instrukcji WWW](browser/README-PL.md). Cała paczka pozostaje poza public_html; publiczny jest tylko zabezpieczony punkt wejścia mm-setup.php.

## Instalacja przez CLI

1. Rozpakuj ZIP do katalogu obok `public_html`, np.
   `/home/user/mm-installer/`.
2. Najpierw:
   ```bash
   php install.php --dry-run --target=/home/user
   ```
3. Jeśli profil został rozpoznany:
   ```bash
   php install.php --target=/home/user
   ```
4. Instalator poprosi w trybie ukrytym o indywidualny
   `MOBILE_INTERNAL_API_SECRET` tej parafii.

Instalator:
- wykrywa zgodny profil,
- dla nieznanej instalacji kończy pracę bez zmian,
- robi backup plików/routingu,
- instaluje wspólny MobileAPI,
- zapisuje aktywny adapter,
- wykonuje preflight,
- wykonuje migracje 001–006,
- instaluje metadane adaptera,
- uruchamia hardening przypisany do profilu,
- zapisuje manifest rollbacku.

## Rollback

Po poprawnym wdrożeniu instalator wypisuje gotowe polecenie:

```bash
php rollback.php --backup=/home/user/mm-installer-backups/YYYYMMDD_HHMMSS
```

Rollback przywraca kod/routing. Migracje bazy są celowo addytywne i nie są
kasowane automatycznie.

## Bezpieczeństwo

- install.php działa przez CLI lub uwierzytelniony kontroler WWW; bezpośrednie żądania HTTP są odrzucane,
- nieznany profil = STOP,
- brak/niepoprawny sekret = STOP,
- profile nie obchodzą kontroli SHA-256 wewnątrz hardenerów,
- sekrety parafii nie trafiają do repo ani ZIP-a,
- adapter wybierany jest przez plik poza webrootem,
- publiczne stuby są identyczne dla wszystkich parafii.

## Dodawanie nowego wariantu parafii

Nie kopiuj całej paczki. Dodaj:
1. `profiles/<wariant>.php` z fingerprintem kompatybilności,
2. adapter w `mobileapi-core/ParishAdapters/<Wariant>/`,
3. ewentualne hardenery wersji,
4. test profilu.

Po merge CI ponownie buduje **ten sam**
`universal-parish-installer.zip`.
