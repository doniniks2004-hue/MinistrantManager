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
    /mobile/bootstrap      one-time handoff -> PHP session
         |                       |
      SQLite                ONLINE / legacy PHP
         |
      OFFLINE
```

Serwer steruje listą modułów. Typ `webview` może zostać dodany bez nowego
APK, o ile korzysta z już obsługiwanych ikon i generycznego WebView.
Typ `native` można reklamować dopiero wtedy, gdy dana wersja Fluttera
rzeczywiście ma wskazany `screen`.

## Format deskryptora

Native:

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

WebView:

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

`path` zawsze jest ścieżką względną aktywnej parafii, nigdy pełnym URL.

## Jedno źródło prawdy dla WebView

`webview_module_registry()` w `modules_builder.php` zawiera jednocześnie:
- id,
- title,
- path,
- icon,
- order,
- required_role,
- opcjonalny warunek włączenia.

Z tego samego rejestru korzystają:
1. `build_modules()` — co dashboard pokazuje,
2. `webview_handoff.php` — do jakiej ścieżki i dla jakiej roli wolno
   wystawić bilet.

Nie ma osobnego allowlistu, który mógłby się rozjechać z dashboardem.

Aktualnie rejestr ma **54 ścieżki WebView** i wszystkie 54 istnieją w
zweryfikowanym backupie legacy Witosy.

## Flow handoff

```
Dashboard
  -> POST /api/v1/mobile/webview/handoff
     Authorization: Bearer <mobile_user_token>
     X-Installation-Id: <uuid>
     body: {"path": "/public/triduum.php"}

backend:
  - waliduje mobile user token,
  - ponownie respektuje device-control-plane,
  - sprawdza path w jednym rejestrze,
  - sprawdza required_role,
  - mintuje losowy, jednorazowy bilet TTL 60 s

WebView
  -> /public/mobile_handoff.php?ticket=...
  - atomowo konsumuje bilet,
  - ponownie sprawdza active + password_changed,
  - tworzy zwykłą sesję PHP,
  - redirectuje wyłącznie do target_path zapisanego przy mincie
```

`mobile_user_token` nigdy nie trafia do URL/JS/WebView.

Bilet jest single-use; drugi consume jest odrzucany.

## Bezpieczeństwo WebView w Flutterze

`LegacyModuleScreen`:
- wpuszcza tylko HTTPS,
- wewnątrz WebView pozwala na host aktywnej parafii,
- inny host otwiera systemowo,
- nie przyjmuje dowolnego zewnętrznego URL z backendu,
- obsługuje historię Back,
- ma stany loading/error/offline,
- WebView cookies są czyszczone przy logout i zmianie użytkownika.

## Role

`required_role` w deskryptorze jest filtrem UX, ale **nie jest jedyną
ochroną**. Backend handoff ponownie sprawdza rolę niezależnie od klienta.

Zweryfikowane przykłady:
- Ministrant → zwykły moduł: dozwolone,
- Ministrant → `users.php`: 403,
- nieznana ścieżka: 400,
- `senior-managers.php`: tylko Admin/Ksiądz, zgodnie z realnym legacy.

## Moduły natywne

Aktualnie gotowe 7/7:
- Mój grafik,
- Ranking,
- Punkty,
- Zastępstwa (odczyt; zapis w zabezpieczonym WebView),
- Obecności,
- Ogłoszenia,
- Profil.

UI native czyta dane z SQLite. Sync sieciowy zapisuje snapshot do bazy
lokalnej; ekran nie renderuje danych biznesowych bezpośrednio z odpowiedzi
HTTP.

## Jak dodać nowy moduł WebView

1. Zweryfikuj realny plik PHP i jego page-level authorization.
2. Dodaj jedną definicję do `webview_module_registry()`.
3. Ustaw `required_role` zgodnie z realną ochroną strony.
4. Jeżeli potrzebna jest nowa nazwa ikony, dodaj mapowanie w Android/iOS.
5. CI + finalnie acceptance.

Nie potrzeba osobnego allowlistu ani nowego `LegacyModuleScreen`.

## Jak dodać nowy moduł native

Native wymaga:
1. kontraktu backend,
2. repozytorium/snapshot,
3. tabel/migracji Drift,
4. sync mapping,
5. rzeczywistego Flutter screen,
6. dopiero wtedy deskryptora `type=native`.

Backend nie może reklamować ekranu native przed jego implementacją.
