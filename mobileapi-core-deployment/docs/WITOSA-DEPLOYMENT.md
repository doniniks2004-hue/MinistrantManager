# Wdrożenie MobileAPI na Witosie — instrukcja krok po kroku

**Zanim zaczniesz: nie mam dostępu sieciowego do prawdziwej Witosy z tego
środowiska.** Wszystko poniżej jest przygotowane i **zweryfikowane
lokalnie** (realny MariaDB + realny PHP + realny HTTP) na dokładnie tym
samym zestawie plików — ale wykonanie na prawdziwym serwerze musi zrobić
ktoś z dostępem.

## Kolejność

```
backup → preflight → migracje → install_mobile_meta.php → pliki →
.htaccess → konto testowe → smoke test → ręczne porównanie web vs
bootstrap → cleanup danych testowych
```

## 1. Backup

```bash
mysqldump -u <user> -p <nazwa_bazy> > witosa_backup_przed_mobileapi_$(date +%Y%m%d_%H%M).sql
```

## 2. Preflight (PRZED migracjami)

```bash
# Skopiuj scripts/preflight.php do /home/<user>/ (obok mobileapi-core/
# i public_html/), potem:
cd /home/<user>
php preflight.php
```

Sprawdza twardo: PHP >= 8.1, rozszerzenie `mysqli`, że `PASSWORD_ARGON2ID`
faktycznie działa (nie tylko że stała istnieje), oraz — jeśli
`mobile_user_tokens` już istnieje z jakiegoś wcześniejszego powodu — czy
jej `UNIQUE KEY` jest poprawnie na samym `installation_id`.

**Kończy się kodem wyjścia 1 i czytelnym błędem, jeśli cokolwiek jest
nie tak — nie przechodź do migracji, dopóki `preflight.php` nie zwróci
`PREFLIGHT OK` (kod 0).**

### Jeśli preflight zgłosi stary, błędny klucz unikalności

(Nie powinno się zdarzyć przy pierwszym wdrożeniu — `mobile_user_tokens`
jeszcze nie istnieje na Witosie — ale gdyby kiedyś trzeba było to
naprawić ręcznie po jakimś wcześniejszym, innym wdrożeniu:)

```sql
-- 1. Sprawdź, czy są konflikty (ten sam installation_id, różni userzy)
SELECT installation_id, COUNT(DISTINCT user_id) AS user_count
FROM mobile_user_tokens
GROUP BY installation_id
HAVING user_count > 1;

-- 2. Jeśli są konflikty: zachowaj NAJNOWSZY wiersz per installation_id
--    (najwyższe id), usuń starsze duplikaty
DELETE t1 FROM mobile_user_tokens t1
INNER JOIN mobile_user_tokens t2
  ON t1.installation_id = t2.installation_id AND t1.id < t2.id;

-- 3. Dopiero teraz zmień klucz
ALTER TABLE mobile_user_tokens DROP INDEX uniq_user_device;
ALTER TABLE mobile_user_tokens ADD UNIQUE KEY uniq_installation_id (installation_id);
```

Uruchom `preflight.php` ponownie, żeby potwierdzić naprawę, dopiero potem
przejdź dalej.

## 3. Migracje (bezpieczne do wielokrotnego uruchomienia)

```bash
mysql -u <user> -p <nazwa_bazy> < migrations/001_mobile_user_tokens.sql
mysql -u <user> -p <nazwa_bazy> < migrations/002_mobile_meta.sql
mysql -u <user> -p <nazwa_bazy> < migrations/003_webview_handoff_tickets.sql
mysql -u <user> -p <nazwa_bazy> < migrations/004_device_authorization_cache.sql
```

```sql
SHOW TABLES LIKE 'mobile_%';
-- oczekiwane: mobile_user_tokens, mobile_meta (obie puste)
SHOW TABLES LIKE 'webview_handoff_tickets';
-- oczekiwana: webview_handoff_tickets (pusta) — hybrydowy dashboard, milestone 2
```

**Uwaga (jeśli 001/002 były już wdrożone wcześniejszą paczką):** ta
runda poszerzyła `mobile_meta.adapter_version` z `VARCHAR(20)` na
`VARCHAR(40)` (nowa wartość `2.1.0-hybrid-dashboard` się nie mieściła).
Migracja 002 w tej paczce ma już poprawny rozmiar — jeśli 002 była
uruchomiona WCZEŚNIEJ z starą wersją pliku, dodatkowo wykonaj:
```sql
ALTER TABLE mobile_meta MODIFY adapter_version VARCHAR(40) NOT NULL;
```

## 4. `install_mobile_meta.php`

```bash
php /home/<user>/mobileapi-core/ParishAdapters/Witosa/install_mobile_meta.php
```

Wypełnia `mobile_meta` (`capabilities: {events:true, schedule:true, ...
reszta:false}`).

## 5. Pliki

### A. `mobileapi-core/` → POZA `public_html/`, jako sąsiad (tak jak dziś `.env`)

```
/home/<user>/mobileapi-core/          <- cała zawartość z tej paczki
/home/<user>/public_html/             <- już istnieje
```

Nigdy nie jest dostępny przez HTTP.

### B. `public_html-additions/api/mobile/*.php` → do `public_html/api/mobile/`

Trzy pliki-zaślepki, ścieżki względne, nic do edycji:
`bootstrap.php`, `session_login.php`, `config.php`.

## 6. `.htaccess` — DOPISZ (nie zastępuj całego pliku!)

Zawartość `public_html-additions/htaccess-snippet.txt` dopisz do
istniejącego `public_html/.htaccess`.

## 7. Konto testowe

```bash
# Skopiuj scripts/create_test_account.php do /home/<user>/, potem:
php create_test_account.php
```

Wypisuje `username` + losowe hasło **tylko raz, tylko na ekranie** —
zapisz od razu, nigdy do repo/gita. Tworzy 3 wpisy w grafiku (dwa bliskie,
jeden celowo daleko w przyszłości, do ręcznej zmiany w panelu WWW w
kroku 9). Wszystkie 3 oznaczone markerem `[MOBILE_TEST_WITOSA]` w opisie
— to po nim `cleanup_test_account.php` je later znajdzie, nie po ID.
Bezpieczne do wielokrotnego uruchomienia (drugi raz odświeża tylko
hasło).

## 8. Smoke test

```bash
chmod +x scripts/smoke_test.sh
./scripts/smoke_test.sh https://parafia-witosa.ministrant.eu mobile_test_witosa
# Skrypt zapyta o hasło interaktywnie (bez echa) — nie podawaj go jako
# argument, nie trafi do historii powłoki ani listy procesów.
```

Ten dokładny skrypt uruchomiłem lokalnie — **9/9 PASS**. Oczekuję
identycznego wyniku na Witosie; jeśli coś się różni, patrz sekcja 11.

## 9. Ręczna weryfikacja: webowy grafik == `/mobile/bootstrap`

1. Obejrzyj w panelu WWW grafik `mobile_test_witosa` (jako Admin, albo
   zaloguj się nim).
2. Zanotuj datę/godzinę/opis/źródło wpisów w oknie -7/+90 dni od dziś.
3. Porównaj z `schedule`+`events` z `/tmp/smoke_bootstrap.json` (zapisany
   po smoke teście).
4. Sprawdź: `event_date` (uwaga na strefę czasową, ISO 8601 z offsetem),
   `source`/`event_source` (`events` = niedziela/święto, `weekday_events`
   = w tygodniu), `id`/`event_id` (format `"events:123"` — celowe, patrz
   `EventsRepositoryInterface`), `schedule` zawiera WYŁĄCZNIE wpisy
   `mobile_test_witosa`.
5. Zmień wpis #3 (daleka przyszłość) w panelu WWW na datę w oknie -7/+90
   dni — **zachowaj prefiks `[MOBILE_TEST_WITOSA]` na początku opisu**,
   jeśli edytujesz tekst (inaczej `cleanup_test_account.php` go nie
   znajdzie) — uruchom smoke test ponownie, sprawdź czy wpis się pojawił.

## 10. Sprzątanie danych testowych

```bash
# Skopiuj scripts/cleanup_test_account.php do /home/<user>/, potem:
php cleanup_test_account.php
```

Usuwa WYŁĄCZNIE: 3 oznaczone wydarzenia + ich wpisy `schedule`, wszystkie
`mobile_user_tokens` konta testowego, samo konto. Nic więcej. Bezpieczne
do wielokrotnego uruchomienia — drugi raz to no-op.

## 11. Czego szukać, jeśli coś zachowuje się inaczej niż lokalnie

- **Wersja PHP** — `preflight.php` to teraz twardo sprawdza (krok 2), nie
  musisz zgadywać.
- **`.htaccess`/mod_rewrite** — jeśli `curl .../api/v1/mobile/config` da
  404 zamiast 200, sprawdź czy reguła z kroku 6 faktycznie się wykonuje.
- **Strefa czasowa serwera** — kod explicit ustawia `Europe/Warsaw` przy
  parsowaniu dat, więc NIE powinno zależeć od domyślnej strefy PHP —
  jeśli daty są przesunięte, to pierwsze podejrzane miejsce.
- **Uprawnienia plików** po wgraniu przez FTP/panel Hostido — czasem
  trzeba ręcznie ustawić 644.

**Wypełnij tę sekcję realnymi obserwacjami po wdrożeniu.**

## 12. Nowość w tej rundzie: hybrydowy dashboard + WebView

Ta wersja paczki dodaje:
- `modules_builder.php` + rozszerzony `config.php` — dashboard
  dynamicznie pokazuje moduły `native`/`webview` sterowane z serwera
  (pełny opis w `docs/HYBRID-MODULES.md`, dostarczonym osobno)
- Mechanizm handoff (`migrations/003`, `webview_handoff.php`,
  `mobile_handoff.php`) — logowanie do WebView bez drugiego hasła
- Ogłoszenia (P1, native) — wpięte w `bootstrap.php`

Do weryfikacji na realnej Witosie dodatkowo: **kliknięcie „Triduum"/
innego modułu WebView z dashboardu faktycznie loguje bez pytania o
hasło** — osobny test od głównego scenariusza logowania z poprzedniej
rundy, warto dodać do checklisty.

## 13. Nowość: device-control plane (WYMAGA KROKU RĘCZNEGO przed działaniem)

Parafia nie ufa już samemu poprawnemu UUID `installation_id` —
`session/login` i `webview/handoff` teraz **potwierdzają z
app.ministrant.eu**, że urządzenie faktycznie istnieje, jest aktywowane,
nie jest revoked, i należy do tej konkretnej parafii.

**Wymagany krok ręczny przed wdrożeniem (bez tego logowanie NIE
zadziała w ogóle):**
1. W panelu admina `app.ministrant.eu` wygeneruj sekret dla tej parafii
   (kolumna `parishes.mobile_internal_api_secret` — migracja centrali
   `2026_09_29_000001_...` musi być już uruchomiona po stronie
   app.ministrant.eu).
2. Skopiuj `public_html-additions/config/mobile_internal_api_secret.php`
   do `public_html/config/` i wklej tam prawdziwy sekret zamiast
   placeholdera (`preflight.php` odmówi kontynuacji, dopóki to zrobisz).
3. Uruchom `migrations/004_device_authorization_cache.sql`.

Cache autoryzacji (lease 10 minut) — `DeviceAuthorizationService`
NIE odpytuje centrali przy każdym żądaniu, tylko gdy lokalny cache
wygasł. Jeśli centrala jest niedostępna: urządzenie z wcześniej znanym
dobrym stanem nadal działa (offline-first, `stale: true` w logach), a
zupełnie nowe/nieznane urządzenie dostaje `503 central_unavailable`
(nigdy nie jest to mylone z `revoked`).

## 14. Czego ta paczka NIE zawiera (celowo)

`session/exchange`, stary `/mobile/sync` (incremental), HOTFIX
`substitution_history` (osobny temat), moduły poza `events`+`schedule`.
