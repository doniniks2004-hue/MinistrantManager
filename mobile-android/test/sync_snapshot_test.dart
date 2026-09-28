import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart';

void main() {
  group('SyncEngine snapshot-first apply (review round, points 6+7)', () {
    test('a fresh snapshot fully REPLACES local events/schedule — a row missing from the new snapshot is gone, not merged', () async {
      final db = AppDatabase.forTesting();
      final engine = SyncEngine(db: db, api: ApiClient(SecureStorageService()), secureStorage: SecureStorageService());

      // Seed a "stale" event that will NOT appear in the next snapshot —
      // simulating a Mass that was deleted server-side. The real legacy
      // tables have no tombstone/deleted_at column at all (see the
      // backend's EventsRepositoryInterface docblock), so the ONLY way
      // this client can ever learn about a server-side deletion is a
      // full replace, never an upsert-only merge.
      await engine.applySnapshotForTesting({
        'generated_at': '2026-10-01T08:00:00+02:00',
        'events': [
          {'id': 'events:1', 'raw_id': 1, 'source': 'events', 'event_date': '2026-10-04T10:00:00+02:00', 'description': 'Stara msza', 'module_id': null, 'is_cancelled': false},
        ],
        'schedule': [],
      });
      expect((await db.select(db.events).get()).length, 1);

      // Next snapshot no longer includes events:1 at all (deleted
      // server-side) and includes a genuinely new events:2 instead.
      await engine.applySnapshotForTesting({
        'generated_at': '2026-10-02T08:00:00+02:00',
        'events': [
          {'id': 'events:2', 'raw_id': 2, 'source': 'events', 'event_date': '2026-10-11T10:00:00+02:00', 'description': 'Nowa msza', 'module_id': null, 'is_cancelled': false},
        ],
        'schedule': [],
      });

      final events = await db.select(db.events).get();
      expect(events.length, 1, reason: 'the stale row is GONE — a plain upsert-only merge would have left 2 rows here');
      expect(events.first.id, 'events:2');

      await db.close();
    });

    test('generated_at from the response is persisted as the snapshot timestamp', () async {
      final db = AppDatabase.forTesting();
      final engine = SyncEngine(db: db, api: ApiClient(SecureStorageService()), secureStorage: SecureStorageService());

      await engine.applySnapshotForTesting({
        'generated_at': '2026-10-01T08:00:00+02:00',
        'events': [],
        'schedule': [],
      });

      final meta = await db.ensureSyncMetadata();
      expect(\n        meta.lastSyncAt?.toUtc(),\n        DateTime.parse('2026-10-01T08:00:00+02:00').toUtc(),\n      );

      await db.close();
    });

    test(
      'point 7: a malformed row partway through the snapshot rolls back the WHOLE transaction — the previous good snapshot survives untouched',
      () async {
        final db = AppDatabase.forTesting();
        final engine = SyncEngine(db: db, api: ApiClient(SecureStorageService()), secureStorage: SecureStorageService());

        // A known-good snapshot first.
        await engine.applySnapshotForTesting({
          'generated_at': '2026-10-01T08:00:00+02:00',
          'events': [
            {'id': 'events:1', 'raw_id': 1, 'source': 'events', 'event_date': '2026-10-04T10:00:00+02:00', 'description': 'Dobra msza', 'module_id': null, 'is_cancelled': false},
          ],
          'schedule': [],
        });

        // A SECOND snapshot where the first event is fine but the SECOND
        // has an unparseable event_date — simulating a malformed server
        // response partway through applying it.
        Object? caught;
        try {
          await engine.applySnapshotForTesting({
            'generated_at': '2026-10-02T08:00:00+02:00',
            'events': [
              {'id': 'events:2', 'raw_id': 2, 'source': 'events', 'event_date': '2026-10-11T10:00:00+02:00', 'description': 'OK', 'module_id': null, 'is_cancelled': false},
              {'id': 'events:3', 'raw_id': 3, 'source': 'events', 'event_date': 'NOT-A-VALID-DATE', 'description': 'Zła data', 'module_id': null, 'is_cancelled': false},
            ],
            'schedule': [],
          });
        } catch (e) {
          caught = e;
        }

        expect(caught, isNotNull, reason: 'the malformed row must actually throw, or this test proves nothing');

        final events = await db.select(db.events).get();
        expect(events.length, 1, reason: 'ROLLBACK must undo BOTH the delete and the one successfully-inserted row from the failed attempt');
        expect(events.first.id, 'events:1', reason: 'the ORIGINAL good snapshot is exactly what survives — not a half-applied mix');

        final meta = await db.ensureSyncMetadata();
        expect(\n          meta.lastSyncAt?.toUtc(),\n          DateTime.parse('2026-10-01T08:00:00+02:00').toUtc(),\n          reason: 'generated_at from the FAILED attempt must not have been persisted either',\n        );

        await db.close();
      },
    );

    test('schedule rows correctly reference canonical event ids, including self-referential weekday_events rows', () async {
      final db = AppDatabase.forTesting();
      final engine = SyncEngine(db: db, api: ApiClient(SecureStorageService()), secureStorage: SecureStorageService());

      await engine.applySnapshotForTesting({
        'generated_at': '2026-10-01T08:00:00+02:00',
        'events': [
          {'id': 'events:5001', 'raw_id': 5001, 'source': 'events', 'event_date': '2026-10-04T10:00:00+02:00', 'description': null, 'module_id': 1, 'is_cancelled': false},
          {'id': 'weekday_events:6001', 'raw_id': 6001, 'source': 'weekday_events', 'event_date': '2026-10-07T18:00:00+02:00', 'description': null, 'module_id': null, 'is_cancelled': false},
        ],
        'schedule': [
          {'id': 'schedule:7001', 'raw_id': 7001, 'event_id': 'events:5001', 'event_source': 'events', 'user_id': 9001, 'guest_name': null, 'is_present': false, 'status': 'assigned'},
          {'id': 'weekday_events:6001', 'raw_id': 6001, 'event_id': 'weekday_events:6001', 'event_source': 'weekday_events', 'user_id': 9001, 'guest_name': null, 'is_present': false, 'status': 'assigned'},
        ],
      });

      final schedule = await db.select(db.scheduleAssignments).get();
      expect(schedule.length, 2);
      final weekdayRow = schedule.firstWhere((s) => s.eventSource == 'weekday_events');
      expect(weekdayRow.id, weekdayRow.eventId, reason: 'a weekday assignment IS the event row — id and event_id must be the same canonical value');

      await db.close();
    });
  });
}
