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

/// schemaVersion history — bump this on every structural change and add a
/// migration step in `_migrate`. NEVER perform a destructive migration
/// (drop/recreate tables) without first confirming `pending_actions` is
/// empty and the team has explicitly agreed local data can be safely
/// re-fetched from the server (see spec §3 / migrations requirement).
///
///   v1 — initial schema (parish_info, events, schedule_assignments,
///        attendance, points, ranking, announcements, substitutions,
///        pending_actions, sync_metadata, dashboard_config_cache,
///        client_config_cache)
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

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          // Example of how future migrations MUST be written — additive,
          // never destructive, and never touching pending_actions rows:
          //
          // if (from < 2) {
          //   await m.addColumn(events, events.someNewColumn);
          // }
          // if (from < 3) {
          //   await m.createTable(someNewTable);
          // }
          //
          // If a genuinely destructive change is unavoidable, it must be
          // gated behind an explicit check that `pendingActions` is empty,
          // and the user must be warned before local data is rebuilt from
          // a fresh bootstrap.
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
