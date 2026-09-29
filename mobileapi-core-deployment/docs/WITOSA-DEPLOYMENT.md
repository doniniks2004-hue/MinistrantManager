# Wdrożenie MobileAPI + mobile legacy hotfix na Witosie

Ta instrukcja opisuje finalny pakiet generowany przez CI jako
`witosa-deployment.zip`.

> Produkcja nie była jeszcze testowana na realnej Witosie/telefonie — zgodnie
> z decyzją produktową acceptance wykonujemy dopiero po funkcjonalnym domknięciu
> aplikacji i brandingu. Kod/paczka są przygotowane tak, aby ten test był
> ostatnim etapem, a nie częścią budowy funkcji.

## Kolejność

```
backup
→ przygotowanie sekretu device-control-plane
→ preflight
→ migracje 001–005
→ install_mobile_meta
→ wdrożenie mobileapi-core + 5 stubów + .htaccess
→ legacy security hardening
→ legacy web hardening
→ legacy substitutions hotfix
→ smoke/acceptance
→ cleanup danych testowych
```

## 1. Backup

Baza:

```bash
mysqldump -u <user> -p <nazwa_bazy> > witosa_backup_przed_mobileapi_$(date +%Y%m%d_%H%M).sql
```

Dodatkowo zachowaj bieżące `public_html/.htaccess` i
`public_html/config/`.

Oba instalatory legacy (security hardening i hotfix zamian) tworzą własne
timestampowane backupy wszystkich plików, które modyfikują.

## 2. Przygotuj device-control-plane PRZED preflightem

Po stronie `app.ministrant.eu`:
1. centralna migracja dodająca `parishes.mobile_internal_api_secret` musi być
   wdrożona,
2. wygeneruj sekret dla Witosy.

Na Witosie:
1. skopiuj
   `public_html-additions/config/mobile_internal_api_secret.php`
   do `public_html/config/mobile_internal_api_secret.php`,
2. zamień placeholder na prawdziwy sekret tej parafii,
3. nie commituj tej wartości do repo.

`MOBILE_CENTRAL_BASE_URL` pozostaje `https://app.ministrant.eu`.

## 3. Preflight

Skopiuj `scripts/preflight.php` do katalogu domowego użytkownika hostingu,
czyli obok `public_html/`, i uruchom:

```bash
cd /home/<user>
php preflight.php
```

Musi zakończyć się:

```
PREFLIGHT OK
```

Sprawdza m.in.:
- PHP >= 8.1,
- mysqli,
- Argon2id,
- poprawny UNIQUE po `installation_id`,
- obecność prawdziwego `MOBILE_INTERNAL_API_SECRET`.

Jeżeli zgłasza błąd — **nie uruchamiaj migracji**.

### Naprawa starego UNIQUE, jeśli preflight tego wymaga

```sql
SELECT installation_id, COUNT(DISTINCT user_id) AS user_count
FROM mobile_user_tokens
GROUP BY installation_id
HAVING user_count > 1;

DELETE t1 FROM mobile_user_tokens t1
INNER JOIN mobile_user_tokens t2
  ON t1.installation_id = t2.installation_id AND t1.id < t2.id;

ALTER TABLE mobile_user_tokens DROP INDEX uniq_user_device;
ALTER TABLE mobile_user_tokens
  ADD UNIQUE KEY uniq_installation_id (installation_id);
```

Potem uruchom preflight ponownie.

## 4. Migracje 001–005

Uruchom w kolejności:

```bash
mysql -u <user> -p <nazwa_bazy> < migrations/001_mobile_user_tokens.sql
mysql -u <user> -p <nazwa_bazy> < migrations/002_mobile_meta.sql
mysql -u <user> -p <nazwa_bazy> < migrations/003_webview_handoff_tickets.sql
mysql -u <user> -p <nazwa_bazy> < migrations/004_device_authorization_cache.sql
mysql -u <user> -p <nazwa_bazy> < migrations/005_device_authorization_cache_lease_hours.sql
```

Migracja 005 dodaje `offline_lease_hours` do lokalnego cache autoryzacji.
Zapobiega bezterminowemu zaufaniu staremu statusowi `active` podczas awarii
centrali.

Jeżeli bardzo stara wersja migracji 002 była już wykonana z
`adapter_version VARCHAR(20)`, wykonaj dodatkowo:

```sql
ALTER TABLE mobile_meta MODIFY adapter_version VARCHAR(40) NOT NULL;
```

## 5. Zainstaluj metadata adaptera

```bash
php /home/<user>/mobileapi-core/ParishAdapters/Witosa/install_mobile_meta.php
```

## 6. Wgraj MobileAPI

### A. Core poza public_html

Finalny układ:

```
/home/<user>/mobileapi-core/
/home/<user>/public_html/
```

Cały katalog `mobileapi-core/` leży poza webrootem.

### B. Pięć stubów do public_html/api/mobile

Z `public_html-additions/api/mobile/` skopiuj:

- `bootstrap.php`
- `config.php`
- `session_login.php`
- `session_change_password.php`
- `webview_handoff.php`

### C. Handoff WebView

Skopiuj:
- `public_html-additions/public/mobile_handoff.php`
  → `public_html/public/mobile_handoff.php`.

### D. .htaccess

**Nie zastępuj całego pliku.**

Dopisz reguły z:
`public_html-additions/htaccess-snippet.txt`.

Finalnie muszą działać:
- `/api/v1/mobile/config`
- `/api/v1/mobile/bootstrap`
- `/api/v1/mobile/session/login`
- `/api/v1/mobile/session/change-password`
- `/api/v1/mobile/webview/handoff`.

## 7. Zastosuj legacy security hardening

Pakiet zawiera:
`scripts/apply_legacy_security_hardening.php`.

Skopiuj go do `/home/<user>/apply_legacy_security_hardening.php`, czyli
obok `public_html/`, i uruchom:

```bash
cd /home/<user>
php apply_legacy_security_hardening.php
```

Poprawny wynik:

```
LEGACY SECURITY HARDENING OK
```

Drugie uruchomienie jest bezpiecznym no-op:

```
LEGACY SECURITY HARDENING: already applied
```

Skrypt przed jakąkolwiek zmianą sprawdza SHA-256 audytowanej wersji legacy,
robi backup, podmienia pliki atomowo, weryfikuje końcowe SHA i rollbackuje
przy błędzie.

Domyka pięć realnych problemów produkcyjnych:
- `upd.php` — wyłącza webowy updater z hardcoded hasłem,
- `receiver.php` — wyłącza publiczny uploader z globalnym tokenem,
- `fix.php` — wyłącza jednorazowy skrypt DB z kluczem w query string,
- `reset.php` — wyłącza publiczny destrukcyjny reset instalacji,
- `public/settings.php` — wymusza CSRF dla destrukcyjnych akcji i usuwa
  przewidywalne `admin/admin` po factory resecie; nowe hasło admina jest
  losowe, jednorazowo wyświetlane i wymusza zmianę przy pierwszym logowaniu.

Jeżeli skrypt zgłosi nieznany SHA-256, **nie wymuszaj podmiany** — oznacza
to, że produkcyjny legacy różni się od audytowanego backupu i trzeba
najpierw zrobić diff.

## 8. Zastosuj legacy web hardening

Pakiet zawiera:
`scripts/apply_legacy_web_hardening.php`.

Skopiuj go do `/home/<user>/apply_legacy_web_hardening.php`, czyli obok
`public_html/`, i uruchom:

```bash
cd /home/<user>
php apply_legacy_web_hardening.php
```

Poprawny wynik:

```
LEGACY WEB HARDENING OK
```

Drugie uruchomienie jest bezpiecznym no-op.

Instalator jest fail-closed: przed zmianą sprawdza SHA-256 audytowanej
wersji, robi backup, zapisuje atomowo, weryfikuje końcowe hashe i
rollbackuje przy błędzie.

Domyka trzy dodatkowe problemy:
- centralny same-origin guard dla mutujących żądań legacy wykonywanych
  w zalogowanej sesji,
- realną weryfikację CSRF na destrukcyjnych akcjach `public/empty.php`,
- bezpieczniejszą obsługę screenshotów w `public/form.php`: MIME jest
  rozpoznawany z zawartości pliku, a upload nie trafia do wykonywalnego
  publicznego webrootu.

Jeżeli produkcyjny plik ma inny SHA niż audytowany baseline, instalator
odmawia podmiany — najpierw wykonaj diff.

## 9. Zastosuj hotfix zastępstw

Pakiet zawiera:
`scripts/apply_substitution_hotfix.php`.

Skopiuj go do `/home/<user>/apply_substitution_hotfix.php`, czyli obok
`public_html/`, i uruchom:

```bash
cd /home/<user>
php apply_substitution_hotfix.php
```

Poprawny wynik zaczyna się od:

```
SUBSTITUTION HOTFIX OK
```

Skrypt:
- weryfikuje SHA-256 audytowanego legacy przed jakąkolwiek zmianą,
- **odmawia nadpisania**, jeżeli produkcyjne pliki różnią się od znanej wersji,
- tworzy `backup_substitution_hotfix_YYYYMMDD_HHMMSS/`,
- zapisuje pliki atomowo,
- weryfikuje końcowe SHA-256,
- rollbackuje dotknięte pliki przy błędzie,
- jest idempotentny — drugie uruchomienie zwraca `already applied`.

Hotfix m.in.:
- wymusza CSRF w finderze i ręcznej zamianie,
- sprawdza role/rodzica/dziecko po stronie serwera,
- eliminuje IDOR,
- blokuje wyścigi przy tworzeniu/akceptacji,
- dla zwykłych `events` zamienia **konkretne wpisy `schedule`**,
  nie całe `event_groups`,
- dla tygodniowych używa `weekday_event_assignments`,
- wycofuje stare, niespójne endpointy mutacji kodem HTTP 410.

Jeżeli skrypt zgłosi różny hash — **nie wymuszaj podmiany**. Najpierw porównaj
produkcyjny plik z audytowaną wersją.

## 10. Wymuszona pierwsza zmiana hasła

Mobile nie obchodzi legacy `password_changed`.

Flow:
1. poprawny login dla konta z `password_changed=0`,
2. serwer odpowiada HTTP 428 `password_change_required` i nie wydaje
   pełnego tokenu,
3. aplikacja pokazuje natywny ekran zmiany hasła,
4. `/session/change-password` ponownie sprawdza hasło i urządzenie,
5. zmiana jest transakcyjna,
6. stare tokeny użytkownika są odwoływane,
7. wydawany jest świeży token,
8. WebView handoff także odmawia dostępu przy `password_changed=0`.

## 11. Konto testowe — dopiero w finalnej rundzie acceptance

```bash
php create_test_account.php
```

Skrypt:
- tworzy/odświeża `mobile_test_witosa`,
- ustawia `password_changed=1`,
- generuje losowe hasło tylko na ekran,
- dodaje oznaczone wpisy `[MOBILE_TEST_WITOSA]`.

Nie zapisuj hasła do repo.

## 12. Smoke test

```bash
chmod +x smoke_test.sh
./smoke_test.sh https://parafia-witosa.ministrant.eu mobile_test_witosa
```

Hasło jest pobierane interaktywnie przez `read -s`, nie przez argument CLI.

Po podstawowym smoke sprawdź w acceptance dodatkowo:
- aktywację QR,
- login,
- first-password flow,
- native 7/7,
- offline + restart,
- WebView bez drugiego logowania,
- role 1/2/3/4/5,
- zakaz handoff do niedozwolonej roli,
- jednorazowość biletu,
- zastępstwa: utworzenie/anulowanie/akceptacja/ręczna zamiana,
- `events ↔ events`, `weekday ↔ weekday` i cross-type,
- user switch/logout,
- revoke urządzenia,
- maintenance,
- update-required.

## 13. Cleanup

```bash
php cleanup_test_account.php
```

Usuwa wyłącznie dane oznaczone przez test oraz konto testowe.

## 14. Rollback

Jeżeli problem dotyczy MobileAPI:
- przywróć poprzedni `.htaccess`,
- usuń/wycofaj nowe stuby,
- przywróć poprzedni `mobileapi-core/`.

Jeżeli problem dotyczy legacy security hardening:
- użyj timestampowanego katalogu
  `backup_legacy_security_*/`.

Jeżeli problem dotyczy legacy web hardening:
- użyj timestampowanego katalogu backupu utworzonego przez
  `apply_legacy_web_hardening.php`.

Jeżeli problem dotyczy zastępstw:
- użyj timestampowanego katalogu
  `backup_substitution_hotfix_*/` utworzonego przez instalator.

Nie kasuj tabel/migracji w panice — najpierw odłącz routing i przywróć kod,
a dopiero potem analizuj dane.

## 15. Co jest celowo poza tym wdrożeniem

- publikacja Google Play / App Store,
- podpis iOS bez Apple Developer,
- finalne assety brandingu (dojdą po dostarczeniu logo/ikony),
- acceptance na realnym telefonie — wykonywany dopiero po finalnym buildzie.
