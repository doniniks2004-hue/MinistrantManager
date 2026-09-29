# HYBRID-MODULES.md

## Architektura

```
                    APP
                     |
              Native Dashboard  <- /mobile/config { modules: [...] }
                     |
         +-----------+-----------+
         |                       |
    NATIVE SCREEN            WEBVIEW (LegacyModuleScreen)
         |                       |
    /mobile/bootstrap      handoff ticket -> PHP session
         |                       |
      SQLite                ONLINE / legacy PHP
         |
      OFFLINE
```

Serwer decyduje, co jest `native` a co `webview` — aplikacja nie ma
zaszytej listy modułów. Nowy moduł PHP po stronie parafii = wpis w
`build_modules()` (backend) + wpis w `webview_path_allowlist()`, zero
nowego APK.

## Format deskryptora modułu

```json
{
  "id": "schedule",
  "title": "Mój grafik",
  "type": "native",
  "screen": "my_schedule",
  "icon": "calendar",
  "order": 10,
  "enabled": true,
  "requires_online": false,
  "required_role": null
}
```

```json
{
  "id": "triduum",
  "title": "Triduum Paschalne",
  "type": "webview",
  "path": "/public/triduum.php",
  "icon": "church",
  "order": 100,
  "enabled": true,
  "requires_online": true,
  "required_role": null
}
```

`path` jest ZAWSZE względny do `server_url` aktywnego urządzenia —
nigdy pełny URL. `required_role: null` = widoczne dla każdego
zalogowanego; `[1, 2]` = tylko te role_id. To jest filtr WYŚWIETLANIA —
rzeczywiste wymuszanie uprawnień dzieje się po stronie serwera
(`webview_handoff.php`'s allowlist, `bootstrap.php`'s własne
filtrowanie po userze), niezależnie od tego, co klient pokazuje.

Wsteczna kompatybilność: `capabilities` (stary kontrakt) nadal działa —
jeśli `/mobile/config` nie zwróci `modules`, `CapabilitiesDashboardAdapter`
buduje równoważną listę z `capabilities`, w DOKŁADNIE tym samym kształcie.

## Flow handoff (bez drugiego logowania)

```
Dashboard -> klik "Triduum"
  -> POST /mobile/webview/handoff  (Authorization: Bearer mobile_user_token, X-Installation-Id)
       body: {"path": "/public/triduum.php"}
       backend: sprawdza path przeciw allowlist, mintuje jednorazowy bilet (64 znaki hex, TTL 60s)
  -> WebView otwiera: {server_url}/public/mobile_handoff.php?ticket=...
       backend: konsumuje bilet ATOMOWO (UPDATE ... WHERE used_at IS NULL) — drugi raz ten sam bilet = odmowa
       ustawia sesję PHP DOKŁADNIE jak normalny login (session_regenerate_id + te same 5 kluczy sesji)
       redirect 302 do ścieżki ZAPISANEJ przy mincie (nigdy z query stringa requestu)
  -> użytkownik widzi Triduum, zalogowany, bez formularza
```

`mobile_user_token` **nigdy** nie trafia do URL, JS, ani WebView — tylko
jednorazowy bilet, który autoryzuje dokładnie jedno załadowanie strony.

Zweryfikowane end-to-end lokalnie: mint → konsumpcja → sesja → redirect
→ dostęp → **drugi raz ten sam bilet poprawnie odrzucony (403)** →
próba niedozwolonej ścieżki poprawnie odrzucona (400).

## Bezpieczeństwo WebView (`LegacyModuleScreen`)

Jeden generyczny komponent dla WSZYSTKICH modułów legacy:

- HTTPS wyłącznie — każda inna schema (`file://`, `http://`) blokowana
  na poziomie `NavigationDelegate`.
- Host allowlisted do **aktywnej parafii** (`Uri.parse(server_url).host`,
  odczytywane przy każdym otwarciu — nigdy zaszyte na sztywno).
- Nawigacja do INNEGO hosta (nawet w ramach linku na stronie) —
  zablokowana wewnątrz WebView, otwierana w systemowej przeglądarce.
- Android back nawiguje historię WebView, jeśli możliwe; dopiero potem
  zamyka ekran (`PopScope` + `controller.canGoBack()`).
- Stany: loading / ready / error (z przyciskiem ponów) / offline
  (komunikat „Ten moduł wymaga połączenia z internetem", bez próby
  pseudo-offline z cache HTML).

## Czyszczenie sesji przy logout/zmianie użytkownika

`UserSessionService.logout()` i `.login()` (przy wykryciu innego
`user.id` niż poprzednio zapisany) obie wołają
`WebViewCookieManager().clearCookies()` — cookie sesji PHP nigdy nie
przechodzi z Adama na Bartka. Wywołanie owinięte w try/catch (best
effort) — brak platformy WebView (np. test jednostkowy) nie blokuje
właściwego czyszczenia SQLite, które jest tym, co faktycznie chroni
dane.

## Jak dodać nowy moduł legacy BEZ nowego APK

1. Dodaj ścieżkę do `webview_path_allowlist()` w `modules_builder.php`.
2. Dodaj wpis do `build_modules()` (id, title, path, ikona, rola).
3. Gotowe — dashboard pokaże go przy następnym `/mobile/config`, klik
   otworzy go przez już istniejący handoff + `LegacyModuleScreen`.

Zero zmian po stronie Fluttera, zero nowego builda.

## Co zostało do migracji native w przyszłości

Patrz `MODULE-MATRIX.md` — sekcja „Native, ale nie zrobione w tej
rundzie" (Punkty, Ranking, Zastępstwa-read, Obecności-read) oraz lista
~25 znalezionych plików PHP jeszcze niewystawionych na dashboard.
