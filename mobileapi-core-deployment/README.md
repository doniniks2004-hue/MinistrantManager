# mobileapi-core-deployment/

**To jest kopia referencyjna paczki wdrożeniowej dla parafii** (Witosa i
każdej kolejnej), dodana do repo wyłącznie po to, żeby dało się ją
przejrzeć/zdiffować na GitHubie — **nie jest wpięta w CI** i nie jest
kopiowana przez żaden workflow.

## Dlaczego to jest osobny folder, nie `mobileapi/`

Folder `mobileapi/` w tym repo to pozostałość Iteracji 1 (szkielet w
stylu Laravel) — **nigdy nie był rzeczywistym celem wdrożenia** dla
prawdziwej parafii i nie jest z nim zsynchronizowany. Realny kod, który
faktycznie trafia na serwer Witosy (i każdej kolejnej parafii), to
dokładnie to, co jest w tym folderze — dostarczane jako
`witosa-deployment.zip` przy okazji odpowiednich rund tej pracy.

## Co tu jest

- `mobileapi-core/` — kod PHP wdrażany POZA `public_html/` (patrz
  `docs/WITOSA-DEPLOYMENT.md`)
- `public_html-additions/` — pliki-zaślepki i config do wgrania
  DO `public_html/`
- `migrations/` — migracje SQL, w kolejności numerycznej
- `scripts/` — `preflight.php`, `create_test_account.php`,
  `cleanup_test_account.php`, `smoke_test.sh`
- `docs/` — pełna instrukcja wdrożenia, matryca modułów, architektura
  hybrydowa

## Dlaczego nie w CI

Ten kod nigdy nie działa samodzielnie — wymaga prawdziwej instalacji
legacy PHP danej parafii (bazy danych, `config/database.php`, realnych
tabel) jako hosta. Weryfikacja odbywa się przez:
1. Lokalne testy end-to-end w środowisku deweloperskim (opisane w
   historii commitów tego repo) — prawdziwy MariaDB + PHP + HTTP,
   syntetyczne dane w kształcie realnego schematu.
2. Realne wdrożenie na Witosie przez zespół z dostępem do serwera,
   według `docs/WITOSA-DEPLOYMENT.md`.

Jeśli w przyszłości powstanie sposób na uruchomienie prawdziwego testu
integracyjnego przeciwko tej paczce w GitHub Actions (np. kontener z
minimalnym legacy PHP), warto to tu podłączyć — na razie to świadomie
poza zakresem.
