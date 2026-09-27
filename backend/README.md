# app.ministrant.eu — backend

Centralny system aktywacji i zarządzania urządzeniami dla aplikacji mobilnej
Ministrant Manager. **Nie przechowuje danych parafialnych** (grafik, obecność,
punkty) — to odpowiedzialność `MinistrantManager-MobileAPI`, instalowanego
w istniejącym backendzie `*.ministrant.eu`. Ten projekt zarządza wyłącznie:
parafiami (aktywna/nieaktywna w sensie mobilnym), urządzeniami, kodami
aktywacyjnymi, kontami administratorów i audytem.

## Wymagania

- PHP 8.2+
- MySQL 8+
- Composer
- (opcjonalnie, zalecane produkcyjnie) Redis lub inny driver cache dla `RateLimiter` — domyślnie działa na cache `database`, co wystarcza do startu

## Instalacja lokalna / stagingowa

Ten katalog zawiera **kod specyficzny dla aplikacji** (`app/`, `database/migrations`,
`resources/views/admin`, `routes/web.php`, `routes/api.php`, `config/auth.php`,
`bootstrap/app.middleware-snippet.php`) — nie pełny szkielet frameworka Laravel.

```bash
composer create-project laravel/laravel app-ministrant-eu "^11.0"
cd app-ministrant-eu

# skopiuj zawartość tego archiwum NA WIERZCH świeżego projektu Laravel,
# nadpisując routes/web.php, routes/api.php i config/auth.php

composer require pragmarx/google2fa bacon/bacon-qr-code

# scal bootstrap/app.middleware-snippet.php do WŁASNEGO bootstrap/app.php
# (rejestracja aliasu middleware 'super_admin' — patrz komentarz w tym pliku)

cp .env.example .env
php artisan key:generate
# uzupełnij dane MySQL w .env

php artisan migrate

# utwórz PIERWSZEGO administratora (musi być SUPER_ADMIN — inaczej nikt
# nie będzie mógł zarządzać kolejnymi kontami):
php artisan tinker
>>> \App\Models\AdminUser::create(['name'=>'Admin','email'=>'admin@ministrant.eu','password'=>bcrypt('ZMIEN_TO_HASLO'),'role'=>'SUPER_ADMIN']);
```

Przy pierwszym logowaniu każdy nowy administrator (bez `totp_enabled`) jest
przekierowywany do `/admin/totp/setup` — konfiguracja TOTP jest obowiązkowa,
nie da się jej pominąć. Zaraz po potwierdzeniu kodu TOTP generowane jest 10
kodów odzyskiwania, pokazywanych dokładnie raz.

## Deploy checklist (produkcja)

- [ ] `APP_ENV=production`, `APP_DEBUG=false` w `.env`
- [ ] `APP_KEY` wygenerowany (`php artisan key:generate`) i **nigdy** nie commitowany
- [ ] HTTPS wymuszony na całej domenie `app.ministrant.eu` (w tym `/.well-known/*` — patrz `docs-app-links.md`), certyfikat automatycznie odnawiany (Let's Encrypt / inny)
- [ ] `SESSION_SECURE_COOKIE=true`, `SESSION_DRIVER=database` (lub redis)
- [ ] MySQL: osobny użytkownik aplikacyjny z ograniczonymi uprawnieniami (nie root), regularne kopie zapasowe skonfigurowane PRZED pierwszym prawdziwym adminem/parafią
- [ ] `php artisan migrate --force` uruchomione na czystej bazie produkcyjnej
- [ ] Pierwszy administrator utworzony jako `SUPER_ADMIN` (patrz wyżej), hasło tymczasowe zmienione, MFA skonfigurowane, 10 kodów odzyskiwania zapisane w bezpiecznym miejscu (menedżer haseł zespołu, nie e-mail)
- [ ] Web server (nginx/Apache) skierowany na `public/`, z blokadą dostępu do `.env`, `storage/`, `vendor/`
- [ ] Cache configu: `php artisan config:cache` po każdym deployu (i **wyczyszczony** przed zmianą `.env` — `php artisan config:clear`)
- [ ] Kolejka: obecnie żadna funkcja NIE wymaga queue workera (wszystko synchroniczne) — jeśli to się zmieni (np. e-maile), dodać `php artisan queue:work` jako usługę systemową (systemd/supervisor)
- [ ] Cron: obecnie NIC nie wymaga harmonogramu — oznaczanie przeterminowanych kodów jako `expired` dzieje się w locie przy każdym sprawdzeniu (`MobileActivationCode::isUsable()`), nie przez cron. Jeśli chcesz też fizycznie zaktualizować kolumnę `status` w bazie (czysto kosmetyczne), dodaj `php artisan schedule:run` przez cron + odpowiednie zadanie
- [ ] `.well-known/assetlinks.json` i `.well-known/apple-app-site-association` uzupełnione realnymi wartościami PRZED publikacją aplikacji (patrz `docs-app-links.md`) — do czasu uzupełnienia mogą zostać jako placeholdery, nie blokują niczego innego
- [ ] Endpoint `GET /api/client-config` zwraca sensowne wartości (zwłaszcza `minimum_supported_*_version` — jeśli ustawione zbyt wysoko względem jeszcze niewydanej aplikacji, zablokuje wszystkich)

## Rollback checklist

- [ ] Kopia zapasowa bazy wykonana BEZPOŚREDNIO przed deployem (nie starsza niż kilka minut)
- [ ] Migracje tego wydania mają odwracalne `down()` — sprawdzone przed deployem (`php artisan migrate:rollback --pretend` na stagingu)
- [ ] Poprzednia wersja kodu otagowana w git przed wdrożeniem nowej (`git tag` / release), żeby rollback kodu był jednym poleceniem
- [ ] Rollback NIE cofa automatycznie zmian w `mobile_activation_codes.used_count` ani `mobile_devices.status` dokonanych między deployem a rollbackiem — jeśli w tym oknie ktoś się aktywował/został dezaktywowany, sprawdź audit_log ręcznie po rollbacku

## Struktura

- `app/Models` — `Parish`, `MobileDevice`, `MobileActivationCode`, `AdminUser` (role `SUPER_ADMIN`/`ADMIN`), `AdminRecoveryCode`, `AuditLog`, `AppConfig`
- `app/Http/Controllers/Admin` — panel administratora: dashboard, parafie, urządzenia, logowanie+TOTP+recovery codes, `AdminManagementController` (SUPER_ADMIN), `SettingsController` (SUPER_ADMIN)
- `app/Http/Controllers/Api` — API konsumowane przez aplikację mobilną: `ActivationController`, `DeviceController`, `ClientConfigController`
- `app/Http/Controllers/Public` — `ActivationLandingController` (fallback `/activate/{token}` dla skanów spoza aplikacji)
- `app/Http/Middleware/EnsureSuperAdmin` — drugi próg autoryzacji nad `auth:admin`
- `app/Services/TokenService` — generowanie/hashowanie (SHA-256) tokenów; surowe tokeny nigdy nie są zapisywane
- `app/Services/RecoveryCodeFormatter` (framework-free, testowalne) + `RecoveryCodeService` (Eloquent) — kody odzyskiwania MFA
- `app/Services/AuditLogger` — centralny log operacji administracyjnych
- `public/.well-known/` — szablony App Links / Universal Links (patrz `docs-app-links.md`)

## Endpointy API (konsumowane przez Flutter)

- `POST /api/activation/check` `{token | display_code}` → dane parafii (bez konsumowania kodu)
- `POST /api/activation/confirm` `{token | display_code, installation_id, platform, device_model, os_version, app_version}` → dane parafii + jednorazowy `device_token` (transakcja + `lockForUpdate()` — bezpieczne przy równoczesnych aktywacjach)
- `POST /api/device/heartbeat` (Bearer device_token) `{app_version, os_version}` → status (`ACTIVE`/`DEVICE_REVOKED`/`PARISH_DISABLED`/`UPDATE_REQUIRED`) + aktualny `offline_lease_hours`
- `POST /api/device/status` (Bearer device_token) → jw., dodatkowo odświeża `last_authorization_check`
- `POST /api/device/sync-ack` (Bearer device_token) → zapisuje `last_sync_at`, wywoływane przez telefon po udanej synchronizacji z subdomeną parafii
- `GET /api/client-config` (bez autoryzacji) → globalna konfiguracja floty: minimalne/najnowsze wersje, store URLs, tryb konserwacji, domyślny offline lease

Rate limiting aktywacji jest rozdzielony na dwa niezależne limity — ogólny
techniczny (60/10min/IP) i właściwy anty-brute-force liczący **wyłącznie
nieudane próby** (5/10min, osobno per IP i per znormalizowany kod) — patrz
`ActivationController` dla pełnego uzasadnienia.

## Role administratorów

`SUPER_ADMIN` — pełny dostęp, w tym zarządzanie kontami innych adminów,
reset MFA, zmiana ról, ustawienia globalne. `ADMIN` — zarządzanie parafiami/
urządzeniami/kodami, bez dostępu do `/admin/admins` i `/admin/settings`.
Nie da się zdegradować ani dezaktywować ostatniego aktywnego `SUPER_ADMIN`
(sprawdzane w `AdminUser::canChangeRoleOf/canDeactivate`).

## TODO przed produkcją

1. Uzupełnić realne wartości w `public/.well-known/assetlinks.json` i `apple-app-site-association` (patrz `docs-app-links.md`) — wymaga finalnego keystore Android i konta Apple Developer.
2. Rozważyć dedykowany cache driver (Redis) dla `RateLimiter` przy większym ruchu — `database` wystarcza na start, ale generuje więcej zapytań pod obciążeniem.
3. Panel z listą `audit_logs` (dane są już zapisywane przy każdej akcji — brakuje tylko widoku listującego/filtrującego).
4. Rozważyć e-mail z potwierdzeniem przy tworzeniu nowego konta administratora (obecnie hasło tymczasowe trzeba przekazać ręcznie/ustnie).
