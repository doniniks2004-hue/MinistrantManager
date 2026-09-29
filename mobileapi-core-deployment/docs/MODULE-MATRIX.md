# MODULE-MATRIX.md

Stan zweryfikowany względem pełnego backupu legacy Witosy z 2026-09-18/24
(`bogumil.ministrant.eu (2).zip`) oraz aktualnego rejestru
`modules_builder.php`.

## Podsumowanie

- bezpośrednie strony `public/*.php` w aktualnym backupie: **92**
- ścieżki WebView wystawione przez MobileAPI: **54/54 istnieją w backupie**
- zaplanowane moduły natywne/offline: **7/7 zaimplementowane**
- pozostałe strony PHP, które nie są osobnym kafelkiem aplikacji: **38**
- brak znanych martwych ścieżek WebView.

Legenda ról: **1 Admin, 2 Ksiądz, 3 Starszy Ministrant, 4 Rodzic, 5 Ministrant**.

## NATIVE (7)

| module_id | Nazwa | Ekran | Status |
|---|---|---|---|
| `schedule` | Mój grafik | `my_schedule` | ✅ offline |
| `ranking` | Ranking | `ranking` | ✅ offline |
| `points` | Historia punktów | `points_history` | ✅ offline |
| `substitutions` | Zastępstwa | `substitutions` | ✅ odczyt offline; zapis przez zabezpieczony WebView |
| `attendance` | Obecności | `attendance` | ✅ dwa źródła danych, bez mieszania |
| `announcements` | Ogłoszenia | `announcements` | ✅ offline |
| `profile` | Moje konto | `profile` | ✅ |

## WEBVIEW — codzienne / formacyjne (3)

| module_id | Plik | Rola |
|---|---|---|
| `justifications` | `justifications.php` | każdy zalogowany |
| `substitution_finder` | `substitution-finder.php` | każdy zalogowany |
| `melodies` | `melodie.php` | każdy zalogowany |

`substitution-finder.php` jest **jedyną kanoniczną ścieżką zapisu zamian**
w aplikacji. Hotfix `scripts/apply_substitution_hotfix.php`:
- wymusza CSRF i autoryzację aktora,
- usuwa IDOR dla rodzica,
- blokuje wyścigi/dwukrotną akceptację,
- sprawdza, czy wskazana msza była rzeczywiście zaoferowana,
- dla `events` operuje na konkretnych wpisach `schedule`, a nie
  `event_groups` (czyli nie zamienia przypadkiem całej grupy),
- dla `weekday_events` używa `weekday_event_assignments`,
- stare `/api/request_substitution.php` i `/api/accept_substitution.php`
  wyłącza kodem HTTP 410.

## WEBVIEW — sezonowe (4)

| module_id | Plik | Warunek |
|---|---|---|
| `summer` | `summer-calendar.php` | aktywny moduł + okno dat |
| `kolenda` | `kolenda-calendar.php` | aktywny moduł + okno dat |
| `wyjazdy` | `wyjazdy-kalendarz.php` | aktywny moduł |
| `triduum` | `triduum.php` | enabled i nie hidden |

## WEBVIEW — Admin/Ksiądz/Starszy (2)

- `gathering_access` → `gathering-access.php`
- `event_manager` → `event_manager.php`

## WEBVIEW — Administracja, Admin/Ksiądz (43)

Rejestr handoff i ochrona stron są dopasowane do realnego legacy.

`kandydaci-admin.php`, `custom_devotions.php`, `points-management.php`,
`users.php`, `statistics.php`, `settings.php`, `ustawienia.php`,
`triduum-admin.php`, `summer-admin.php`, `kolenda-admin.php`,
`kolenda-podglad.php`, `kolenda-obecnosc.php`, `wyjazdy-admin.php`,
`meetings-config.php`, `msze.php`, `parent-assignment.php`,
`announcements.php`, `groups.php`, `auto-generate-events.php`,
`generate-week.php`, `nabozenstwa.php`, `devotion_settings.php`,
`church_attendance_check.php`, `priest_attendance_review.php`,
`devotional_ranking.php`, `devotional_points_config.php`,
`triduum-attendance.php`, `form.php`, `attendance.php`,
`attendance-history.php`, `attendance-report.php`,
`schedule_quick_edit.php`, `manual-meeting.php`, `rotation-config.php`,
`mass-config.php`, `sunday_mass_config.php`, `sunday_mass_generator.php`,
`user-add.php`, `user-edit.php`, `import-users.php`, `akcept.php`,
`manual-swap.php`, `senior-managers.php`.

### Dwie różne strony ustawień — rozstrzygnięte

To **nie są duplikaty**:
- `settings.php` — ustawienia systemowe/administracyjne,
- `ustawienia.php` — dane parafii oraz ustawienia RODO/prawne.

Obie istnieją w aktualnym backupie, obie są linkowane przez aktualny
`sidebar.php` i obie mają ochronę roli Admin/Ksiądz.

### manual-swap / senior-managers — rozstrzygnięte

Aktualne pliki mają jawne ograniczenie do ról **1/2**. Rejestr MobileAPI
również dopuszcza wyłącznie Admin/Ksiądz. `manual-swap.php` jest ponadto
objęty hotfixem CSRF i korzysta z poprawionej funkcji zamiany konkretnych
przypisań.

## WEBVIEW — statyczne (2)

- `polityka-prywatnosci.php`
- `regulamin.php`

Dostępne każdemu zalogowanemu.

## NIE JEST OSOBNYM KAFELKIEM APLIKACJI (38)

Poniższe pliki **istnieją**, ale nie powinny być bezpośrednim modułem
nawigacyjnym:

`accept_substitution.php`, `account-edit.php`, `church_attendance.php`,
`dashboard.php`, `download-document.php`, `druk-kafelki.php`,
`druk-new.php`, `druk.php`, `empty.php`, `event-add.php`,
`event-details.php`, `event-edit.php`, `force-change-password.php`,
`gathering-attendance.php`, `gathering-details.php`, `gathering-pdf.php`,
`generate_csv_report.php`, `generate_excel_report.php`,
`get-niedzielnik.php`, `get-slowo-na-dzis.php`,
`get_attendance_for_event.php`, `get_events_for_date.php`,
`justifications_ajax.php`, `login.php`, `meeting-functions.php`,
`points-history.php`, `points.php`, `points_management_addon.php`,
`print-view-new.php`, `print-view.php`, `schedule.php`,
`search-parent.php`, `sidebar-with-gatherings.php`,
`substitution-ajax.php`, `substitution-functions.php`,
`substitutions.php`, `triduum-pdf.php`, `zgloszenie-kandydata.php`.

Główne powody:
- login/dashboard/profile/schedule/points zostały zastąpione przez flow
  natywny,
- pliki AJAX/helper/action są wywoływane przez inne strony,
- wydruki/eksporty są akcjami z paneli WebView,
- `zgloszenie-kandydata.php` jest publicznym formularzem dla osoby
  **niezalogowanej**, więc celowo nie trafia do dashboardu użytkownika.

## Wymuszona zmiana hasła — rozwiązane

`force-change-password.php` nie jest kafelkiem. Mobile ma własny,
serwerowo egzekwowany flow:
1. poprawne dane logowania + `password_changed=0` → HTTP 428
   `password_change_required`, bez wydania pełnego tokenu;
2. natywny ekran „Ustaw nowe hasło”;
3. `POST /api/v1/mobile/session/change-password` ponownie weryfikuje
   aktualne hasło i autoryzację urządzenia;
4. zmienia hasło w transakcji, ustawia `password_changed=1`, odwołuje
   wcześniejsze tokeny użytkownika i wydaje świeży token;
5. istniejące tokeny oraz WebView handoff również odmawiają dostępu,
   gdy `password_changed=0`.

To zamyka również krótki race między wystawieniem biletu WebView a
administracyjnym resetem hasła.
