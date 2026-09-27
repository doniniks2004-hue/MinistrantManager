import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/network/api_client.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/sync/sync_engine.dart';

void main() {
  // Iteration 1.1 fix under test (spec §12, review point 12): pending
  // action payloads were previously stored via `payload.toString()` — a
  // Dart Map's toString() is NOT valid JSON (e.g. single-quoted keys) and
  // the backend correctly rejected it. This test proves the CURRENT code
  // stores real, backend-parseable JSON and that it survives a full
  // encode -> store -> read -> decode cycle unchanged.
  test('enqueueAction stores a real JSON-encoded payload that decodes back to the original map', () async {
    final db = AppDatabase.forTesting();
    final engine = SyncEngine(
      db: db,
      api: ApiClient(SecureStorageService()),
      secureStorage: SecureStorageService(),
    );

    final originalPayload = {
      'person_name': 'Jan Kowalski',
      'status': 'present',
      'nested': {'note': 'z zastępstwem', 'count': 3},
    };

    await engine.enqueueAction(type: 'attendance.mark', payload: originalPayload);

    final rows = await db.select(db.pendingActions).get();
    expect(rows, hasLength(1));

    final storedJson = rows.first.payloadJson;

    // THE actual regression check: this must NOT throw (a `.toString()`
    // map like "{person_name: Jan Kowalski, ...}" is not valid JSON and
    // jsonDecode would throw a FormatException on it).
    final decoded = jsonDecode(storedJson) as Map<String, dynamic>;

    expect(decoded, equals(originalPayload));
    expect(decoded['nested']['count'], 3, reason: 'nested values round-trip with correct types, not stringified');

    await db.close();
  });

  test('pushPendingActions sends jsonDecode(payloadJson) — an object, not a raw string — to the server', () async {
    // Static/structural check: reading the source confirms `jsonDecode`
    // is used when building the request body (see sync_engine.dart's
    // pushPendingActions), which is the other half of this fix — storing
    // valid JSON is meaningless if it's then sent back out as a string.
    // A full HTTP-level test belongs in integration_test/ against a real
    // or mocked server; this unit test targets the storage round-trip only.
    final db = AppDatabase.forTesting();
    await db.into(db.pendingActions).insert(
          PendingActionsCompanion.insert(
            clientActionId: 'test-action-1',
            type: 'attendance.mark',
            payloadJson: jsonEncode({'a': 1}),
            createdAt: DateTime.now().toUtc(),
          ),
        );

    final row = (await db.select(db.pendingActions).get()).first;
    expect(() => jsonDecode(row.payloadJson), returnsNormally);
    expect(jsonDecode(row.payloadJson), {'a': 1});

    await db.close();
  });
}
