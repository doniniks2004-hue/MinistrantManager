import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'tables.dart';
import 'cipher/cipher_engine.dart';
import 'cipher/multi_ciphers_engine.dart';

part 'app_database.g.dart';

/// Plain combined row for "Mój grafik" (milestone scope) — a schedule
/// assignment joined with the event it's for. Not a Drift table itself,
/// just the shape `AppDatabase.watchMySchedule()` emits.
class MyScheduleEntry {
  const MyScheduleEntry({required this.schedule, required this.event});
  final ScheduleAssignment schedule;
  final Event event;
}


/// schemaVersion history — bump this on every structural change and add a
/// migration step in `_migrate`. NEVER perform a destructive migration
/// (drop/recreate tables) without first confirming `pending_actions` is
/// empty and the team has explicitly agreed local data can be safely
/// re-fetched from the server (see spec §3 / migrations requirement) —
/// UNLESS the table being recreated is itself a pure read-only server
/// cache with no user-authored rows and no foreign-key relationship INTO
/// pending_actions, in which case recreating it is always safe (the next
/// successful bootstrap simply repopulates it) — see v2 below.
///
///   v1 — initial schema (parish_info, events, schedule_assignments,
///        attendance, points, ranking, announcements, substitutions,
///        pending_actions, sync_metadata, dashboard_config_cache,
///        client_config_cache)
///   v2 — review round: Events/ScheduleAssignments' columns changed
///        completely (Iteration 1's placeholder title/starts_at/
///        ends_at/person_name/role/version/updated_at shape replaced by
///        the real legacy backend's actual field names — see tables.dart).
///        Both are pure read-only snapshot caches (Iteration 2's
///        snapshot-first model) with no pending_actions foreign key, so
///        the v1->v2 migration safely DROPS + RECREATES only these two
///        tables; nothing else is touched.
@DriftDatabase(tables: [
  ParishInfo,
  Events,
  ScheduleAssignments,
  Attendance,
  Points,
  Ranking,
  Announcements,
  Substitutions,
  PendingActions,
  SyncMetadata,
  DashboardConfigCache,
  ClientConfigCache,
])
class AppDatabase extends _$AppDatabase {
  /// [encryptionKey] MUST come from
  /// SecureStorageService.getOrCreateDbEncryptionKey() — never hardcode
  /// it, never derive it from anything predictable.
  AppDatabase(String encryptionKey, {CipherEngine cipherEngine = const MultiCiphersEngine()})
      : super(_openConnection(encryptionKey, cipherEngine));

  /// TEST-ONLY constructor (Iteration 1.1 point 13): an ephemeral,
  /// unencrypted in-memory database with no dependency on
  /// path_provider/flutter_secure_storage platform channels, so unit
  /// tests (`flutter test`, not `integration_test`) can exercise real
  /// SyncEngine/ConfigService logic against a REAL Drift database without
  /// needing a device/emulator. Never use this outside test code — it
  /// deliberately bypasses CipherEngine.verifyCipherActive() entirely,
  /// which is exactly wrong for anything touching real user data.
  @visibleForTesting
  AppDatabase.forTesting() : super(NativeDatabase.memory());

  /// TEST-ONLY constructor (review round, point 2): like [forTesting], but
  /// backed by a real FILE instead of an anonymous in-memory database, so
  /// a migration test can pre-populate that file with a raw v1 schema,
  /// then reopen it through this constructor and observe the real
  /// `onUpgrade` path run. No encryption (same caveat as [forTesting]).
  @visibleForTesting
  AppDatabase.forTestingAtFile(File file) : super(NativeDatabase(file));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            // v1 -> v2 (review round, point 2): Events/ScheduleAssignments
            // are pure read-only snapshot caches (Iteration 2's
            // snapshot-first model) — no user-authored data, no foreign
            // key from pending_actions into either. Recreating them from
            // scratch is safe; the next successful
            // SyncEngine.fetchAndApplySnapshot() simply repopulates them,
            // exactly like any other snapshot fetch already does.
            // Deliberately NOT touching pending_actions, sync_metadata,
            // dashboard/client config cache, or parish_info.
            await m.deleteTable('events');
            await m.deleteTable('schedule_assignments');
            await m.createTable(events);
            await m.createTable(scheduleAssignments);
          }
          //
          // Template for the NEXT migration:
          // if (from < 3) {
          //   await m.addColumn(events, events.someNewColumn);
          // }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  // --- Convenience queries used by SyncEngine / UI ---

  Future<SyncMetadataData> ensureSyncMetadata() async {
    final existing = await (select(syncMetadata)..where((t) => t.id.equals(1))).getSingleOrNull();
    if (existing != null) return existing;
    final row = SyncMetadataCompanion.insert(id: const Value(1));
    await into(syncMetadata).insert(row);
    return (select(syncMetadata)..where((t) => t.id.equals(1))).getSingle();
  }

  Stream<List<PendingAction>> watchPendingActions() => select(pendingActions).watch();

  /// Spec §19: dashboard/module config must be cached and used even when
  /// the parish server is temporarily unreachable — it is never allowed to
  /// just disappear. Replaces the single cached row atomically.
  Future<void> saveDashboardConfig(int schemaVersion, String configJson) async {
    await into(dashboardConfigCache).insertOnConflictUpdate(
      DashboardConfigCacheCompanion.insert(
        id: const Value(1),
        schemaVersion: schemaVersion,
        configJson: configJson,
        fetchedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<DashboardConfigCacheData?> getDashboardConfig() =>
      (select(dashboardConfigCache)..where((t) => t.id.equals(1))).getSingleOrNull();

  Future<void> saveClientConfig(String configJson) async {
    await into(clientConfigCache).insertOnConflictUpdate(
      ClientConfigCacheCompanion.insert(
        id: const Value(1),
        configJson: configJson,
        fetchedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<ClientConfigCacheData?> getClientConfig() =>
      (select(clientConfigCache)..where((t) => t.id.equals(1))).getSingleOrNull();

  /// Review round (milestone "Mój grafik", point 3): called whenever a
  /// DIFFERENT user signs in on this device than whoever was signed in
  /// before, and on explicit logout — BEFORE the app shows any content to
  /// the new session. Wipes exactly the user-scoped business tables
  /// (events/schedule/attendance/points/ranking/announcements/
  /// substitutions), PLUS pendingActions (a queued write authored by the
  /// PREVIOUS user must never be submitted under the new user's session
  /// once actions/write exists). Deliberately does NOT touch: parishInfo
  /// (same parish, same device — no reason to lose it), syncMetadata
  /// (device-level auth-check timestamp/offline-lease-hours, unrelated to
  /// which human is signed in — the very next successful sync overwrites
  /// its lastSyncAt anyway), dashboardConfigCache/clientConfigCache
  /// (parish/fleet-level config, not user-specific).
  Future<void> wipeUserScopedBusinessData() async {
    await transaction(() async {
      await delete(events).go();
      await delete(scheduleAssignments).go();
      await delete(attendance).go();
      await delete(points).go();
      await delete(ranking).go();
      await delete(announcements).go();
      await delete(substitutions).go();
      await delete(pendingActions).go();

      // Review round fix: `lastSyncAt` describes the USER's snapshot
      // ("when was the data now-being-wiped last fetched") — it must be
      // cleared here too, or the NEXT user to sign in on this device
      // would see an offline banner reading "dane z 12:30" from the
      // PREVIOUS user's last sync, before their own first bootstrap
      // completes. Deliberately does NOT touch `lastAuthorizationCheck`
      // or `offlineLeaseHours` — both are DEVICE-level (app.ministrant.eu
      // auth-check timestamp / fleet-wide lease policy), unrelated to
      // which human is signed in, and clearing them would incorrectly
      // reset the device's own offline-lease countdown.
      await (update(syncMetadata)..where((t) => t.id.equals(1)))
          .write(const SyncMetadataCompanion(lastSyncAt: Value(null)));
    });
  }

  /// "Mój grafik" (milestone scope, point 5/6): the schedule screen reads
  /// ONLY this stream — never HTTP directly (point 6, non-negotiable).
  /// The server already filters `schedule` down to the calling user's own
  /// assignments (see the backend's bootstrap.php) — no further filtering
  /// happens here, this is a straight join for display.
  Stream<List<MyScheduleEntry>> watchMySchedule() {
    final query = select(scheduleAssignments).join([
      innerJoin(events, events.id.equalsExp(scheduleAssignments.eventId)),
    ]);
    return query.watch().map(
          (rows) => rows
              .map((row) => MyScheduleEntry(
                    schedule: row.readTable(scheduleAssignments),
                    event: row.readTable(events),
                  ))
              .toList(),
        );
  }

  Future<void> wipeAllParishData() async {
    // Called on DEVICE_REVOKED / PARISH_DISABLED / manual reset.
    // Deliberately does NOT touch schemaVersion — only row data. This is
    // the "best-effort while the connection still works" first step of a
    // revoke — see closeAndDeleteFiles() below for the actual
    // crypto-erase RevocationHandler performs afterwards; this method
    // alone is NOT sufficient for spec §21/§25 (RODO) on its own, since
    // `DELETE FROM` does not guarantee the underlying pages are
    // unrecoverable from the file on disk.
    // Includes dashboardConfigCache (parish-specific — must not leak into
    // the next parish this device might ever be activated for) but NOT
    // clientConfigCache (global fleet config — store URLs, min versions —
    // has nothing to do with any one parish and is harmless/useful to
    // keep showing immediately after a reset, before the app can reach
    // app.ministrant.eu again).
    await transaction(() async {
      await delete(parishInfo).go();
      await delete(events).go();
      await delete(scheduleAssignments).go();
      await delete(attendance).go();
      await delete(points).go();
      await delete(ranking).go();
      await delete(announcements).go();
      await delete(substitutions).go();
      await delete(pendingActions).go();
      await delete(syncMetadata).go();
      await delete(dashboardConfigCache).go();
    });
  }

  /// Review round 2, point 2 — crypto-erase, not just row deletion:
  /// closes this connection (required before the file can be safely
  /// deleted on every platform), then deletes the SQLite file itself AND
  /// its `-wal`/`-shm`/`-journal` siblings. WAL mode in particular leaves
  /// pages containing OLD row versions in the `-wal` file even after
  /// `DELETE FROM` inside the main file — deleting only the main file
  /// would leave plaintext-adjacent (well, cipher-page) remnants behind.
  ///
  /// Does NOT delete the encryption key — that is
  /// SecureStorageService.deleteDbEncryptionKey()'s job, called
  /// separately by RevocationHandler in the right order (this method
  /// first, while the connection can still close cleanly; the key
  /// second). After this call, this AppDatabase INSTANCE is unusable —
  /// the caller must construct a brand new one (with a brand new key)
  /// before the app can be used again; see main.dart's
  /// `_rebuildDatabaseAfterRevocation`.
  Future<void> closeAndDeleteFiles() async {
    await close();

    final file = await _databaseFile();
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final sibling = File('${file.path}$suffix');
      if (await sibling.exists()) {
        await sibling.delete();
      }
    }
  }
}

Future<File> _databaseFile() async {
  final dbFolder = await getApplicationDocumentsDirectory();
  return File(p.join(dbFolder.path, 'ministrant_manager.sqlite'));
}

LazyDatabase _openConnection(String encryptionKey, CipherEngine cipherEngine) {
  return LazyDatabase(() async {
    final file = await _databaseFile();

    return NativeDatabase.createInBackground(
      file,
      setup: (rawDb) {
        // Cipher selection lives entirely behind the CipherEngine
        // abstraction (see cipher/cipher_engine.dart) — SQLite3MultipleCiphers
        // exclusively, no legacy fallback (review round 2, point 1).
        cipherEngine.applyCipherPragmas(rawDb, encryptionKey);

        // MANDATORY (review point 11, verbatim): "nie wystarczy samo
        // wykonanie PRAGMA key... dodać test/guard sprawdzający
        // dostępność ciphera przed rozpoczęciem pracy na danych." This
        // throws CipherNotActiveException — and therefore refuses to open
        // the database at all — rather than silently proceeding
        // unencrypted if the expected cipher extension isn't actually
        // compiled into whatever sqlite3 binary got loaded.
        cipherEngine.verifyCipherActive(rawDb);
      },
    );
  });
}
