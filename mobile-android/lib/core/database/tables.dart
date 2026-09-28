import 'package:drift/drift.dart';

/// Everything the app needs to render fully offline after the first
/// bootstrap. Column shapes deliberately mirror the JSON envelope returned
/// by `{parish_server}/api/v1/mobile/bootstrap` — see the backend's
/// parish-subdomain-api-reference/README.md.

class ParishInfo extends Table {
  IntColumn get id => integer()();
  TextColumn get name => text()();
  TextColumn get slug => text()();
  TextColumn get serverUrl => text()();
  TextColumn get settingsJson => text().withDefault(const Constant('{}'))();

  @override
  Set<Column> get primaryKey => {id};
}

class Events extends Table {
  // Review round fix (point 4/5): `id` is the CANONICAL string key the
  // real backend sends — "{source}:{raw_id}" (e.g. "events:17" /
  // "weekday_events:17") — never the bare integer, because events.id and
  // weekday_events.id are independent sequences that DO collide.
  TextColumn get id => text()();
  IntColumn get rawId => integer()();
  TextColumn get source => text()(); // 'events' | 'weekday_events'
  DateTimeColumn get eventDate => dateTime()();
  TextColumn get description => text().nullable()();
  IntColumn get moduleId => integer().nullable()();
  BoolColumn get isCancelled => boolean().withDefault(const Constant(false))();

  // Review round fix (point 5): no `version`/`updatedAt` — this is a
  // snapshot-first, read-only mirror of the real legacy `events`/
  // `weekday_events` tables, neither of which has anything resembling
  // those columns. Inventing fake version=1/updatedAt=now() values just
  // to keep an old incremental-sync-shaped column around was explicitly
  // rejected ("Nie chcę adaptera pełnego sztucznych pól... Snapshot nie
  // potrzebuje version ani updated_at do read-only"). The whole table's
  // content for a given fetch window is replaced atomically on every
  // successful bootstrap instead — see SyncEngine.replaceScheduleSnapshot().

  @override
  Set<Column> get primaryKey => {id};
}

class ScheduleAssignments extends Table {
  // Same canonical-key reasoning as Events.id above. For a
  // weekday_events-sourced assignment, this equals eventId — the
  // assignment IS the event row, there is no separate "schedule row" for
  // it (see LegacyMysqlScheduleRepository's docblock on the backend).
  TextColumn get id => text()();
  IntColumn get rawId => integer()();
  TextColumn get eventId => text()(); // canonical id of the EVENT this assignment is for
  TextColumn get eventSource => text()(); // 'events' | 'weekday_events'
  IntColumn get userId => integer().nullable()();
  TextColumn get guestName => text().nullable()();
  BoolColumn get isPresent => boolean().withDefault(const Constant(false))();
  TextColumn get status => text()(); // 'assigned' | 'substitution_needed'

  // No version/updatedAt — same reasoning as Events above.

  @override
  Set<Column> get primaryKey => {id};
}

class Attendance extends Table {
  TextColumn get id => text()();
  TextColumn get eventId => text()();
  TextColumn get personName => text()();
  TextColumn get status => text()(); // present / absent / excused
  DateTimeColumn get recordedAt => dateTime()();
  TextColumn get payloadJson => text()();

  @override
  Set<Column> get primaryKey => {id};
}

class Points extends Table {
  TextColumn get id => text()();
  TextColumn get personName => text()();
  IntColumn get amount => integer()();
  TextColumn get reason => text().nullable()();
  DateTimeColumn get awardedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Ranking extends Table {
  TextColumn get id => text()(); // person id/name as used by the server, stable across syncs
  TextColumn get personName => text()();
  IntColumn get totalPoints => integer()();
  IntColumn get position => integer().nullable()();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Announcements extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  DateTimeColumn get publishedAt => dateTime()();
  BoolColumn get isRead => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Substitutions extends Table {
  TextColumn get id => text()();
  TextColumn get eventId => text().nullable()();
  TextColumn get fromPerson => text()();
  TextColumn get toPerson => text().nullable()();
  TextColumn get status => text()(); // requested / approved / rejected
  TextColumn get payloadJson => text()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Queue of user actions performed while offline (or just to decouple UI
/// writes from network timing). Each row is pushed to
/// `{parish_server}/api/v1/mobile/actions` and removed only after the
/// server confirms it (applied OR already_applied OR a conflict the user
/// has resolved) — see SyncEngine.pushPendingActions().
class PendingActions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get clientActionId => text().unique()(); // UUID, generated at creation time
  TextColumn get type => text()(); // "attendance", "schedule_edit", ...
  TextColumn get payloadJson => text()();
  IntColumn get baseVersion => integer().nullable()(); // only set for versioned edits
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();

  // No explicit `primaryKey` override here (review round 3.x point 7):
  // `integer().autoIncrement()()` on `id` ALREADY makes it the primary
  // key — build_runner correctly rejected the redundant override with
  // "Tables can't override primaryKey and use autoIncrement()".
}

/// Single-row table tracking sync + auth-check state.
class SyncMetadata extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get cursor => text().nullable()();
  DateTimeColumn get lastSyncAt => dateTime().nullable()();
  DateTimeColumn get lastAuthorizationCheck => dateTime().nullable()();
  // Mirrors the server's current `offline_lease_hours` config (spec §10).
  // Refreshed on every successful /device/status or /device/heartbeat call
  // so a central change (e.g. 72 -> 24) takes effect on next connectivity,
  // not just at install time. Falls back to 72 if never set — see
  // OfflineLease.defaultHours.
  IntColumn get offlineLeaseHours => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Spec §15/§19: the parish's own dashboard layout + module list, fetched
/// from `{parish_server}/api/v1/mobile/config` and cached here so a
/// change on the server (reorder modules, rename, hide one) takes effect
/// on next sync WITHOUT a new app release — and so the dashboard still
/// renders correctly when the device is offline (spec §19: config must
/// survive a temporarily-unreachable server, same as business data).
/// Single-row table; the whole config blob is replaced atomically on each
/// successful fetch, never partially merged.
class DashboardConfigCache extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  IntColumn get schemaVersion => integer()();
  TextColumn get configJson => text()(); // the full {"dashboard": ..., "modules": [...]} envelope
  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Spec decision #6 (client-config): global, app.ministrant.eu-owned
/// fleet configuration (store URLs, min/latest versions, maintenance
/// mode) — DELIBERATELY a separate table/cache from DashboardConfigCache,
/// which is per-parish business config from a completely different
/// server. Also single-row, also replaced atomically.
class ClientConfigCache extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get configJson => text()();
  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
