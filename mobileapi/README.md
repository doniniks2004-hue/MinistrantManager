# Ministrant Manager — MobileAPI

Installable into the EXISTING `*.ministrant.eu` parish backend (spec
decision #7). This is deliberately a separate package from
`MinistrantManager-Backend` (`app.ministrant.eu`) — different
responsibility, different deployment target, different lifecycle.

```
app.ministrant.eu           *.ministrant.eu (existing MM + this package)
  ↓ manages fleet              ↓ serves business data
MinistrantManager-Backend    MinistrantManager-MobileAPI
```

## Structure

- `Contracts/` — repository interfaces. The seam between "mobile API
  logic" and "your actual Ministrant Manager data" (spec decision #7).
- `DTO/` — plain data objects passed between layers.
- `Actions/` — `ActionDispatcher`: idempotency + optimistic concurrency
  (spec §13/§14). Framework-free, fully tested.
- `Sync/` — `SyncService`: incremental sync + tombstones (spec §10,
  decision #7). Framework-free, fully tested.
- `Middleware/` — `VerifyDeviceTokenService` (framework-free, fully
  tested tenant-isolation logic) + `VerifyDeviceToken` (Laravel adapter,
  NOT INTEGRATED — see docs/TESTING.md).
- `Config/` — server-driven UI schema + module version gating (spec
  §15–§19). Framework-free, fully tested.
- `Controllers/` — Laravel HTTP controllers wiring the above to
  `/api/v1/mobile/*`. NOT INTEGRATED (needs Laravel to run at all).
- `Repositories/Fake/` — **test doubles only, never bind in production**
  (spec decision #7 — no fake repositories pretending to be a finished
  integration).
- `database/migrations/` — `mobile_sync_changes`, `mobile_action_log`,
  and a template for adding `version` columns to your real business
  tables.
- `Tests/` — real, executable tests. Run with `bash Tests/run_all.sh`.
  See `docs/TESTING.md` for exactly what is and isn't covered.
- `docs/INTEGRATION.md` — how to wire real MM adapters in Iteration 2.

## Installing into an existing Laravel-based MM backend

```bash
composer config repositories.mobileapi path ../MinistrantManager-MobileAPI
composer require i-ban/ministrant-manager-mobileapi:@dev
```

(or simply copy this directory in and add its PSR-4 mapping to your own
`composer.json` — it has no dependencies of its own beyond PHP 8.2+ for
everything except `Controllers/` and `Middleware/VerifyDeviceToken.php`,
which need `illuminate/http`, already present in any Laravel app.)

Then follow `docs/INTEGRATION.md` step by step. Do not bind any
`Repositories/Fake/*` class in a real `AppServiceProvider`.
