# MODULE-MATRIX.md

Pełna inwentaryzacja modułów Ministrant Managera, zbudowana z **realnego
kodu** parafii Witosa (`src/partials/sidebar.php` — jedyne prawdziwe
źródło nawigacji — i listing `public/*.php`), nie z pamięci ani
założeń. Legenda `Status`: ✅ gotowe i zweryfikowane, 🔶 częściowe,
⬜ nie zaczęte (dostępne przez generic WebView bez dodatkowej pracy).

## Native (offline)

| module_id | Nazwa | Route/Screen | Offline | R/W | Rola | Status | Blocker |
|---|---|---|---|---|---|---|---|
| `schedule` | Mój grafik | `my_schedule` | tak | R | każdy | ✅ | — |
| `announcements` | Ogłoszenia | `announcements` | tak | R | każdy | ✅ | — |
| `profile` | Moje konto | `profile` | tak | R | każdy | ✅ | — |
| `points` | Historia punktów | `points_history` | tak | R | każdy | ⬜ | brak repozytorium PHP (`points` table istnieje, adapter nie) |
| `ranking` | Ranking | `ranking` | tak | R | każdy | ⬜ | ranking to projekcja z `points` — wymaga zapytania agregującego po stronie PHP, nie zrobione |
| `substitutions` | Zastępstwa | `substitutions` | tak | R (write→WebView) | każdy | ⬜ | `substitution_requests`/`substitution_history` mają znany bug (patrz HOTFIX-substitution_history.md) — odczyt bezpieczny do zrobienia, ale nie zrobiony w tej rundzie |
| `attendance` | Obecności | `attendance` | tak | R (write→WebView) | każdy | ⬜ | dwa różne źródła (`schedule.is_present` vs `gathering_attendance`) wymagają osobnego mapowania — nie zrobione |

## WebView — codzienne/częste

| module_id | Nazwa | Path | Wymaga online | R/W | Rola | Status |
|---|---|---|---|---|---|---|
| `justifications` | Usprawiedliwienia | `/public/justifications.php` | tak | R/W | każdy | ✅ (allowlist+handoff gotowe) |
| `substitution_finder` | Znajdź zastępstwo | `/public/substitution-finder.php` | tak | R/W | każdy | ✅ |

## WebView — sezonowe (włączane/wyłączane przez panel WWW)

| module_id | Nazwa | Path | Warunek włączenia (realna logika z sidebar.php) | Status |
|---|---|---|---|---|
| `summer` | Kalendarz wakacyjny | `/public/summer-calendar.php` | `summer_module.is_active` + okno `date_from`/`date_to` | ✅ |
| `kolenda` | Kolędy | `/public/kolenda-calendar.php` | `kolenda_module.is_active` + okno dat | ✅ |
| `wyjazdy` | Wyjazdy i wydarzenia | `/public/wyjazdy-kalendarz.php` | `wyjazdy_module.is_active` (bez okna dat) | ✅ |
| `triduum` | Triduum Paschalne | `/public/triduum.php` | `triduum_config`: `module_enabled=1` i `module_completely_hidden≠1` | ✅ |

**Uwaga o „Obozach"**: w realnym kodzie Witosy nie ma osobnej tabeli/modułu
`obozy` — `summer_module`/`summer_events`/`summer_signups` obejmuje
zarówno wakacje, jak i obozy jako jedno zjawisko. Traktowanie ich jako
dwóch osobnych pozycji w dashboardzie (jak w oryginalnej liście) nie
odzwierciedla realnej struktury danych — `summer` już to pokrywa.

## WebView — administracyjne (rola: Admin=1, Ksiądz=2, czasem Starszy=3)

| module_id | Nazwa | Path | Rola | Status |
|---|---|---|---|---|
| `gathering_access` | Obecność na zbiórkach | `/public/gathering-access.php` | 1,2,3 | ✅ |
| `event_manager` | Zwalnianie z mszy | `/public/event_manager.php` | 1,2,3 | ✅ |
| `kandydaci` | Kandydaci | `/public/kandydaci-admin.php` | 1,2 | ✅ |
| `custom_devotions` | Nabożeństwa własne | `/public/custom_devotions.php` | 1,2 | ✅ |
| `points_management` | Zarządzaj punktami | `/public/points-management.php` | 1,2 | ✅ |
| `users_admin` | Użytkownicy | `/public/users.php` | 1,2 | ✅ |
| `statistics` | Statystyki | `/public/statistics.php` | 1,2 | ✅ |
| `settings_admin` | Ustawienia | `/public/settings.php` | 1,2 | ✅ |
| `triduum_admin` | Triduum — panel | `/public/triduum-admin.php` | 1,2 | ✅ |

## Znalezione w kodzie, ale NIEwystawione jeszcze na dashboard

Znalezione podczas przeglądu `public/*.php`, poza już wymienionymi
wyżej — zgodnie z zasadą „jeśli znajdziesz kolejne moduły, dodaj je do
matrycy":

| Plik | Prawdopodobna funkcja | Rekomendacja |
|---|---|---|
| `groups.php` | Zarządzaj grupami ministrantów | webview, admin |
| `msze.php` | Zarządzaj mszami (konfiguracja) | webview, admin |
| `generate-week.php` | Generuj msze w tygodniu | webview, admin |
| `auto-generate-events.php` | Generuj niedziele/święta | webview, admin |
| `nabozenstwa.php` | Konfiguracja nabożeństw | webview, admin |
| `devotion_settings.php` | Widoczność nabożeństw | webview, admin |
| `parent-assignment.php` | Przypisz rodzica | webview, admin |
| `meetings-config.php` | Zarządzaj zbiórkami (config) | webview, admin |
| `rotation-config.php` | Konfiguracja rotacji służby | webview, admin |
| `mass-config.php` | Konfiguracja mszy | webview, admin |
| `devotional_ranking.php` | Obecność na nabożeństwach (raport) | webview, admin |
| `devotional_points_config.php` | Punkty za nabożeństwa stałe | webview, admin |
| `church_attendance_check.php` | Tryb kościelnego (skanowanie obecności) | webview, rola specjalna (kościelny) |
| `priest_attendance_review.php` | Zatwierdzanie obecności przez księdza | webview, 1,2 |
| `account-edit.php` | Edycja własnego konta (legacy) | **NIE wystawiać** — zastąpione przez natywny `profile` |
| `force-change-password.php` | Wymuszona zmiana hasła | webview, warunkowe (flaga `force_password_change` w sesji) |
| `justification_details.php` / `justifications_ajax.php` | Szczegóły/AJAX usprawiedliwień | część `justifications`, nie osobny moduł |
| `senior-managers.php` | Zarządzanie starszymi ministrantami | webview, admin |
| `import-users.php` | Import użytkowników (CSV?) | webview, admin |
| `search-parent.php` | Wyszukiwanie rodzica (AJAX) | część `parent-assignment`, nie osobny moduł |
| `manual-swap.php`, `manual-meeting.php` | Ręczne operacje admina | webview, admin |
| `schedule_quick_edit.php` | Szybka edycja grafiku | webview, admin |
| `druk*.php`, `print-view*.php`, `generate_csv_report.php`, `generate_excel_report.php`, `gathering-pdf.php`, `triduum-pdf.php` | Eksport/druk raportów PDF/CSV/Excel | webview, admin — nie ma sensu przepisywać natywnie |
| `download-document.php` | Pobieranie załączników | webview |
| `regulamin.php`, `polityka-prywatnosci.php` | Strony statyczne | webview, publiczne |
| `form.php` | Kontakt partnerski | webview, admin |
| `get-niedzielnik.php`, `get-slowo-na-dzis.php` | Widżety treści dnia | wbudowane w dashboard.php dziś — do rozważenia jako natywny widget w przyszłości, nie teraz |
| `empty.php` | (prawdopodobnie placeholder/nieużywany) | pominąć |

Wszystkie powyższe **DAJĄ SIĘ otworzyć już dziś** przez istniejący
generic `LegacyModuleScreen`, jeśli dodać ich ścieżkę do
`webview_path_allowlist()` w `modules_builder.php` i ewentualnie
osobny wpis modułu w `build_modules()` — infrastruktura (handoff,
allowlist, WebView shell) jest wspólna dla wszystkich, więc dodanie
kolejnego modułu legacy do dashboardu nie wymaga nowego APK.

## Podsumowanie stanu tej rundy

- **Native + offline, gotowe i zweryfikowane end-to-end**: Mój grafik,
  Ogłoszenia, Moje konto (3/7 z docelowej listy P1)
- **Native, ale nie zrobione w tej rundzie** (backend brak): Punkty,
  Ranking, Zastępstwa (read), Obecności (read) — bezpieczny fallback:
  dashboard poprawnie pokazuje „Ten moduł wymaga nowszej wersji
  aplikacji" zamiast się wywalać, jeśli capability kiedyś włączona bez
  odpowiadającego ekranu
- **WebView + handoff, w pełni gotowe i przetestowane**: 15 modułów
  (2 codzienne, 4 sezonowe, 9 administracyjnych)
- **Znalezione, nie wystawione**: ~25 kolejnych plików PHP, gotowa
  ścieżka dodania każdego bez nowego APK
