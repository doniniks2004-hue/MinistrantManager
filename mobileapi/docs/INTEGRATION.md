# Integrating this package with the existing Ministrant Manager backend

This is a **contracts-first** package (spec decision #7). It does not
know anything about your real database schema — that's the point: it
lets Iteration 2 wire real adapters in without this package (or its
tests) changing.

## What you write in Iteration 2

For each interface in `Contracts/`, one class implementing it against
your real Eloquent models, e.g.:

```php
class MinistrantManagerScheduleRepository implements ScheduleRepositoryInterface
{
    public function bootstrap(DeviceContext $ctx): array
    {
        return ScheduleAssignment::where('parish_id', $ctx->parishId)
            // ...->where('minister_id', $ctx->userId) once user identity exists
            ->get()
            ->map(fn ($row) => [/* map to the wire shape your Flutter app expects */])
            ->all();
    }
}
```

Bind it in your `AppServiceProvider`:

```php
$this->app->bind(ScheduleRepositoryInterface::class, MinistrantManagerScheduleRepository::class);
```

For `VersionedRecordRepositoryInterface`, the critical correctness
requirement is that `applyVersionedUpdate()` is ATOMIC — either:

```php
$affected = DB::table('schedule_assignments')
    ->where('id', $id)
    ->where('version', $expectedVersion)
    ->update(array_merge($changes, ['version' => $expectedVersion + 1]));

if ($affected === 0) {
    throw new VersionConflictException(
        (array) DB::table('schedule_assignments')->find($id),
        DB::table('schedule_assignments')->where('id', $id)->value('version')
    );
}
```

or `SELECT ... FOR UPDATE` inside a transaction, re-checking the version
before writing (same pattern as the Backend package's
`ActivationController::confirm()` fix for the `max_uses` race — see that
package's docblocks).

## What you DON'T need to write in Iteration 1

Nothing — this whole package is designed so Iteration 1 ships with zero
production bindings for these interfaces. `Repositories/Fake/*` exist
ONLY for `Tests/*Test.php` and must never be bound in a real
`AppServiceProvider`.

## MANDATORY for non-versioned action handlers (review round 3, point 5)

`ActionDispatcher`'s claim mechanism (`tryClaim()`/`finalize()`/
`failClaim()` — see `ActionLogRepositoryInterface`'s docblock for the
full explanation) guarantees at most one ACTIVE claim owner for a given
`client_action_id` at any moment. It does **NOT** by itself guarantee a
non-versioned handler's `apply()` runs exactly once across that action's
entire lifetime — a process crash between a successful mutation and
`finalize()` leaves the claim reclaimable after `$staleAfterSeconds`, and
the next (sequential) caller runs `apply()` again.

Before binding a real, non-versioned handler (attendance, points,
substitutions, announcements-read, ...) in Iteration 2, it MUST satisfy
at least one of:

- **(a) Be idempotent on `client_action_id` by construction.** E.g. a
  points award recorded as one ledger row keyed by (or containing)
  `client_action_id`, with the running total computed by summing the
  ledger — replaying the same `client_action_id` either upserts the same
  row unchanged or is rejected by a unique constraint, never double-counts.
  An "increment a counter column in place" implementation is NOT
  idempotent and must not be used for a non-versioned handler without (b).
- **(b) Wrap claim + mutation + finalize in one DB transaction**, when
  `ActionLogRepositoryInterface`'s storage and the business data share
  the same database — so a crash before commit rolls both back together,
  and a stale-reclaim can never find a claim whose mutation half already
  silently happened.

Pick (a) where the operation naturally supports it (most append-only
domain events do); reach for (b) only where it doesn't and the two
storages genuinely share one transactional database. Document which one
each handler relies on in its own class docblock when writing it.

## Wiring VerifyDeviceToken

1. Implement `DeviceTokenStoreInterface::lookup()` — either:
   - a local read of a table synced/replicated from `app.ministrant.eu`'s
     `mobile_devices` (fast, no network hop, needs a sync mechanism), or
   - a cached (short-TTL) HTTP call to `app.ministrant.eu`'s
     `POST /api/device/status` equivalent (simpler, adds latency + a hard
     dependency on app.ministrant.eu being reachable from this parish's
     server for every request unless cached).
2. Register `VerifyDeviceToken::class` as route middleware on every
   `/api/v1/mobile/*` route, placed AFTER whatever resolves
   `$request->attributes->set('current_parish_id', ...)` from the
   subdomain — that resolution is assumed existing MM infrastructure.
