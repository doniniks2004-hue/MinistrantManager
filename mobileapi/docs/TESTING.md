# What was actually tested, and what wasn't

This package is split deliberately into two halves with very different
testability:

## Framework-free (tested, executed, passing — see Tests/)

`DTO/`, `Contracts/` (pure interfaces), `Actions/ActionDispatcher.php`,
`Sync/SyncService.php`, `Middleware/VerifyDeviceTokenService.php`,
`Config/*.php`, and every class under `Repositories/Fake/` have ZERO
dependency on Laravel or any database. They were executed with plain
`php` (PHP 8.3, no Composer, no PHPUnit — see below for why) against the
Fake repositories, and every test in `Tests/*Test.php` passes. Run them
yourself:

```bash
bash Tests/run_all.sh
```

This actually exercises, with real assertions that really run:

- **Idempotency** (spec §13): a duplicated `client_action_id` runs the
  handler exactly once, second call returns `already_applied`.
- **Optimistic concurrency / conflicts** (spec §14, and the exact
  scenario in spec §39): two "devices" editing the same record from a
  stale `base_version` get a `409`-shaped `conflict` result with the
  CURRENT server record, and the repository state proves the second
  writer's change was never applied.
- **Tombstones + incremental sync + tenant isolation at the sync layer**
  (spec §10, decision #7).
- **The spec §36 tenant-isolation test, verbatim**: a token issued for
  parish A used against parish B's subdomain → `TENANT_MISMATCH` / 403 —
  and, symmetrically, that this isn't a blanket lockout (A's token still
  works against A, B's own token still works against B).
- **Server-driven UI safety net** (spec §17/decision #13): an unknown
  component name never fails validation destructively, and spec §18's
  version-gating example (module needs 2.4.0, device has 2.1.0 → not
  supported) passes literally as written in the spec.

## Laravel-dependent (written, syntax-checked, NOT executed)

`Controllers/*.php` and `Middleware/VerifyDeviceToken.php` require
`illuminate/http` and Laravel's service container to run at all. **This
environment could not install Laravel** — `composer create-project` and
plain `composer require laravel/framework` both fail here because
Packagist (`repo.packagist.org`) is not reachable from this sandbox's
network (only npm/PyPI/crates.io/GitHub/Ubuntu archives are). Every file
in this package was checked with `php -l` (real syntax validation, not a
guess) and passes, but none of the Laravel-dependent files have been
executed end-to-end against a real request. They are marked
`NOT INTEGRATED` in their own docblocks.

**What this means for you:** once this package is `composer require`'d
into a real Laravel project (where Packagist IS reachable), the
Controllers/Middleware need an actual integration test run (a real HTTP
request through the real middleware stack) before you trust them beyond
"the PHP parses". The framework-free core they delegate to is already
proven; the adapter layer around it is not yet.

## Concurrency test (in the Backend package, not here)

The `max_uses` race-condition fix lives in `MinistrantManager-Backend`
(`ActivationController`), not in this package — but it's worth noting
here too: that one WAS executed as a real two-OS-process race using
SQLite (`BEGIN IMMEDIATE` standing in for MySQL's `SELECT ... FOR
UPDATE`), and passed. See that package's own test-status notes.
