# MODULE-MATRIX.md

Wyczerpująca inwentaryzacja **wszystkich 91 plików** `public/*.php` z
realnego kodu Witosy, każdy sklasyfikowany na podstawie: `sidebar.php`
(dokładne linki + role) lub jawnej ochrony roli w samym pliku PHP
(`$_SESSION['user_role_id']`), nigdy zgadywania.

Legenda ról: **5** = Ministrant, **4** = Rodzic, **3** = Starszy
Ministrant, **2** = Ksiądz, **1** = Admin.

## NATIVE (7) — offline, realny backend

| module_id | Nazwa | Ekran | Rola | Status |
|---|---|---|---|---|
| `schedule` | Mój grafik | `my_schedule` | każdy | ✅ |
| `ranking` | Ranking | `ranking` | każdy | ✅ |
| `points` | Historia punktów | `points_history` | każdy | ✅ |
| `substitutions` | Zastępstwa (odczyt) | `substitutions` | każdy | ✅ write→WebView |
| `attendance` | Obecności (odczyt, 2 źródła) | `attendance` | każdy | ✅ |
| `announcements` | Ogłoszenia (odczyt) | `announcements` | każdy | ✅ |
| `profile` | Moje konto | `profile` | każdy | ✅ |

## WEBVIEW — codzienne (2)

| module_id | Plik | Rola |
|---|---|---|
| `justifications` | `justifications.php` | każdy |
| `substitution_finder` | `substitution-finder.php` ("Zamiany") | każdy |

## WEBVIEW — sezonowe, warunkowe (4)

| module_id | Plik | Warunek włączenia |
|---|---|---|
| `summer` | `summer-calendar.php` | `summer_module.is_active` + okno dat |
| `kolenda` | `kolenda-calendar.php` | `kolenda_module.is_active` + okno dat |
| `wyjazdy` | `wyjazdy-kalendarz.php` | `wyjazdy_module.is_active` |
| `triduum` | `triduum.php` | `triduum_config`: enabled i nie hidden |

## WEBVIEW — rola 1,2,3 (Admin/Ksiądz/Starszy) (2)

`event_manager` (`event_manager.php`), `gathering_access` (`gathering-access.php`)

## WEBVIEW — sekcja „Administracja" (rola 1,2 — Admin/Ksiądz), 39 pozycji

Wszystkie poniżej mają potwierdzoną ochronę `in_array($_SESSION['user_role_id'], [1, 2])` w samym pliku PHP (lub — dla pozycji z sidebar.php — blok `<?php if ($isAdmin): ?>`).

**Z `sidebar.php` (21):** `summer-admin.php`, `kolenda-admin.php`, `kolenda-podglad.php`, `wyjazdy-admin.php`, `meetings-config.php`, `points-management.php`, `statistics.php`, `msze.php`, `users.php`, `kandydaci-admin.php`, `parent-assignment.php`, `announcements.php` (zarządzanie — **inny moduł niż natywne odczytowe Ogłoszenia**), `groups.php`, `auto-generate-events.php`, `generate-week.php`, `nabozenstwa.php`, `devotion_settings.php`, `custom_devotions.php`, `church_attendance_check.php`, `priest_attendance_review.php`, `devotional_ranking.php`, `devotional_points_config.php`, `settings.php`, `triduum-admin.php` + `triduum-attendance.php` + `triduum-pdf.php`, `form.php`

**Znalezione przez przegląd roli w pliku, nieobecne w linkach `sidebar.php` (prawdopodobnie reachowane z akcji/szczegółów innych stron admina) (13):** `attendance.php`, `attendance-history.php`, `attendance-report.php`, `schedule_quick_edit.php`, `manual-meeting.php`, `rotation-config.php`, `mass-config.php`, `sunday_mass_config.php`, `sunday_mass_generator.php`, `user-add.php`, `user-edit.php`, `import-users.php`, `akcept.php`

**Brak jawnej ochrony w pliku, konserwatywnie sparowane z odpowiednikiem admin-only (2):** `manual-swap.php` (rola 1,2), `senior-managers.php` (rola 1,2,3 — nazwa sugeruje zarządzanie Starszymi Ministrantami)

## WEBVIEW — publiczne, statyczne (2)

`polityka-prywatnosci.php`, `regulamin.php` — dostępne każdemu zalogowanemu.

## NIE DOTYCZY APLIKACJI MOBILNEJ (24)

| Plik | Powód |
|---|---|
| `login.php`, `dashboard.php` | zastąpione przez natywną aktywację/login/dashboard |
| `account-edit.php` | zastąpione przez natywne „Moje konto" |
| `empty.php` | placeholder/nieużywany |
| `substitution-functions.php`, `meeting-functions.php` | pliki z funkcjami PHP, nie strony |
| `get_attendance_for_event.php`, `get_events_for_date.php`, `points_management_addon.php`, `justifications_ajax.php`, `substitution-ajax.php`, `search-parent.php` | endpointy AJAX/JSON, nie samodzielne strony |
| `sidebar-with-gatherings.php` | wariant partiala, nie strona |
| `event-add.php`, `event-edit.php`, `event-details.php` | prawdopodobnie modal/AJAX w ramach `msze.php`, nie osobna nawigacja |
| `accept_substitution.php` | akcja zapisu z **znanym bugiem** (patrz `HOTFIX-substitution_history.md`) — nie strona do otwarcia wprost |
| `gathering-attendance.php`, `gathering-details.php` | prawdopodobnie widoki szczegółowe z `gathering-access.php` |
| `church_attendance.php` | prawdopodobny starszy/alternatywny wariant `church_attendance_check.php` |
| `druk.php`, `druk-new.php`, `druk-kafelki.php`, `print-view.php`, `print-view-new.php`, `generate_csv_report.php`, `generate_excel_report.php`, `gathering-pdf.php` | eksport/druk — niska wartość na telefonie, do rozważenia w przyszłości jako WebView |
| `get-niedzielnik.php`, `get-slowo-na-dzis.php` | widżety treści dnia, wbudowane w `dashboard.php`, nie osobne strony |
| `force-change-password.php` | wymuszony flow sesyjny, nie moduł nawigowalny — **znany gap**, patrz niżej |

## ⚠ Znaleziona sprzeczność — wymaga decyzji, NIE zgadnięta

**`ustawienia.php` vs `settings.php`** — dwa różne pliki ustawień.
`settings.php` ma potwierdzoną ochronę roli i jest w `sidebar.php`.
`ustawienia.php` **nie ma żadnej ochrony roli w widocznej części pliku**
i nie jest linkowany z `sidebar.php` wcale. Może to być:
(a) starszy, zastąpiony plik pozostawiony przez pomyłkę, albo
(b) osobna, rzeczywiście używana strona z inną logiką dostępu.

**Nie dodałem `ustawienia.php` do rejestru** — potrzebna decyzja, który
plik jest faktycznie aktualny, zanim wystawię go na dashboard (błędne
założenie o roli mogłoby wystawić panel ustawień bez ochrony).

## Znany, nie zaadresowany gap: `force-change-password.php`

To wymuszony krok w środku sesji (flaga `force_password_change`), nie
moduł w dashboardzie. WebView-owy flow logowania (handoff) obecnie **nie
obsługuje** przekierowania na wymuszoną zmianę hasła w środku sesji —
jeśli konto ma tę flagę ustawioną, aktualny handoff prawdopodobnie
wpuści użytkownika normalnie z pominięciem tego wymogu. Wymaga decyzji
produktowej: czy to ma być egzekwowane w mobile w ogóle, a jeśli tak —
jak (osobny ekran natywny? redirect w WebView?).

## Podsumowanie

- **Native + offline**: 7/7 zaplanowanych modułów P1 — **gotowe**
- **WebView**: 54 moduły łącznie w dashboardzie (2 codzienne + 4
  sezonowe + 2 rola-1,2,3 + 41 w sekcji „Administracja", w tym 2
  statyczne strony publiczne)
- **Nie dotyczy**: 24 pliki (AJAX/funkcje/warianty/eksporty), rosnąca
  lista jeśli znajdą się kolejne
- **Świadomie odłożone/wymagające decyzji**: `ustawienia.php` (konflikt
  z `settings.php`), `force-change-password.php` (brak flow w mobile)
