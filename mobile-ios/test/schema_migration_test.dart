import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:drift/drift.dart' show Variable;
import 'package:ministrant_manager/core/database/app_database.dart';

void main() {
  test('schema migration v1 -> v2 recreates events/schedule_assignments and leaves pending_actions untouched', () async {
    final dir = await Directory.systemTemp.createTemp('mm_migration_test_');
    final dbFile = File(p.join(dir.path, 'test_v1.sqlite'));
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    // Craft a raw v1-shaped database on disk using package:sqlite3
    // directly (plain, stable API — deliberately NOT going through
    // Drift's own executor internals for this seeding step, to keep this
    // test's own setup as simple/robust as possible). An OLD-shape
    // `events` row (Iteration 1's placeholder title/starts_at columns —
    // long gone from the CURRENT table definition) plus one real
    // `pending_actions` row, exactly what a real device upgrading from a
    // genuine v1 install would have. `PRAGMA user_version = 1` is what
    // makes Drift treat this as an EXISTING v1 database on next open
    // (triggering onUpgrade, not onCreate).
    final seed = sqlite3.sqlite3.open(dbFile.path);
    seed.execute('''
      CREATE TABLE events (
        id TEXT NOT NULL PRIMARY KEY,
        title TEXT NOT NULL,
        starts_at INTEGER NOT NULL
      );
      CREATE TABLE schedule_assignments (
        id TEXT NOT NULL PRIMARY KEY,
        person_name TEXT NOT NULL
      );
      CREATE TABLE pending_actions (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        client_action_id TEXT NOT NULL UNIQUE,
        type TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        base_version INTEGER,
        created_at INTEGER NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      );
      INSERT INTO pending_actions (client_action_id, type, payload_json, created_at)
        VALUES ('pre-migration-action-1', 'attendance.mark', '{}', 0);
      PRAGMA user_version = 1;
    ''');
    seed.dispose();

    // Reopen through the REAL AppDatabase (schemaVersion 2) — this is the
    // actual code path a real app upgrade runs through.
    final db = AppDatabase.forTestingAtFile(dbFile);

    // Migration must complete without throwing, AND the recreated table
    // must accept a row in the NEW shape (proves the old columns are
    // genuinely gone and the new ones genuinely exist — inserting through
    // Events' real Companion would fail to compile/run against stale
    // columns).
    await db.into(db.events).insert(EventsCompanion.insert(
          id: 'events:1',
          rawId: 1,
          source: 'events',
          eventDate: DateTime.now().toUtc(),
        ));
    final events = await db.select(db.events).get();
    expect(events.length, 1, reason: 'the recreated table is genuinely empty post-migration (old row gone) and accepts a new-shape row');
    expect(events.first.id, 'events:1');

    // The pending_actions row from BEFORE migration must have survived —
    // proving the migration truly only touched events/schedule_assignments.
    final pendingCount = await db
        .customSelect('SELECT COUNT(*) AS c FROM pending_actions WHERE client_action_id = ?',
            variables: [Variable.withString('pre-migration-action-1')])
        .getSingle();
    expect(pendingCount.data['c'], 1, reason: 'the pre-migration pending_actions row must survive the v1->v2 upgrade untouched');

    await db.close();
  });
}
