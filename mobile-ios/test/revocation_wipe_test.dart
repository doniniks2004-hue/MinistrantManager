import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/database/app_database.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/core/offline/snapshot_store.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/features/revocation/revocation_handler.dart';

class _Storage extends SecureStorageService {
  String? parish = 'parish-a';
  bool keyDeleted = false;
  bool keyDeleteFails = false;

  @override
  Future<String?> get parishId async => parish;

  @override
  Future<void> deleteSnapshotEncryptionKey() async {
    if (keyDeleteFails) throw StateError('secure storage unavailable');
    keyDeleted = true;
  }
}

class _Store extends SnapshotStore {
  _Store() : super(encryptor: SnapshotEncryptor(hexKey: '1' * 64));
  bool clearFails = false;
  String? cleared;

  @override
  Future<void> clearForParish({required String parishId}) async {
    if (clearFails) throw const FileSystemException('directory is locked');
    cleared = parishId;
  }
}

void main() {
  late AppDatabase db;
  late _Storage storage;
  late _Store store;
  late RevocationHandler handler;

  setUp(() {
    db = AppDatabase.forTesting();
    storage = _Storage();
    store = _Store();
    handler = RevocationHandler(db: db, secureStorage: storage, snapshotStore: store);
  });
  tearDown(() => db.close());

  test('both steps succeed: the wipe is complete', () async {
    expect(await handler.wipeSnapshotsAndKey(), isTrue);
    expect(store.cleared, 'parish-a');
    expect(storage.keyDeleted, isTrue);
  });

  test('F7: a failure to delete the files STILL destroys the key, and the wipe is reported incomplete', () async {
    store.clearFails = true;
    expect(await handler.wipeSnapshotsAndKey(), isFalse);
    expect(storage.keyDeleted, isTrue, reason: 'files left behind are unreadable without the key');
  });

  test('a failure to destroy the key is reported, and the files are still deleted', () async {
    storage.keyDeleteFails = true;
    expect(await handler.wipeSnapshotsAndKey(), isFalse);
    expect(store.cleared, 'parish-a');
  });

  test('both failing is reported, and nothing throws', () async {
    store.clearFails = true;
    storage.keyDeleteFails = true;
    expect(await handler.wipeSnapshotsAndKey(), isFalse);
  });

  test('no parish known: nothing to delete, but the key is still destroyed', () async {
    storage.parish = null;
    expect(await handler.wipeSnapshotsAndKey(), isTrue);
    expect(store.cleared, isNull);
    expect(storage.keyDeleted, isTrue);
  });
}
