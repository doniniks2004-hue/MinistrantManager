import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/secure/secure_storage_service.dart';
import 'package:ministrant_manager/core/startup/install_marker.dart';

class _Storage extends SecureStorageService {
  _Storage({this.credentials = false});

  bool credentials;
  int cleared = 0;
  bool clearFails = false;

  @override
  Future<bool> get hasCredentials async => credentials;

  @override
  Future<void> clearAfterDeletedInstall() async {
    if (clearFails) throw StateError('keychain unavailable');
    cleared++;
    credentials = false;
  }
}

void main() {
  late Directory root;
  late Directory support;
  late File database;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mm_marker_');
    support = Directory('${root.path}/support');
    database = File('${root.path}/documents/ministrant_manager.sqlite');
  });

  tearDown(() async => root.delete(recursive: true));

  InstallMarker marker() => InstallMarker(supportDirectory: support, databaseFile: database);
  File markerFile() => File('${support.path}/install_marker');

  test('REINSTALL: credentials in the keychain, no marker, no database -> cleared', () async {
    final storage = _Storage(credentials: true);
    expect(await marker().clearCredentialsOfDeletedInstall(storage), isTrue);
    expect(storage.cleared, 1);
    expect(markerFile().existsSync(), isTrue);
  });

  test('the next start does nothing (the marker is there)', () async {
    final storage = _Storage(credentials: true);
    await marker().clearCredentialsOfDeletedInstall(storage);
    storage.credentials = true; // the user activated again after the reinstall
    expect(await marker().clearCredentialsOfDeletedInstall(storage), isFalse);
    expect(storage.cleared, 1, reason: 'the new activation is left alone');
  });

  test('a first start with nothing in the keychain only leaves the marker', () async {
    final storage = _Storage();
    expect(await marker().clearCredentialsOfDeletedInstall(storage), isFalse);
    expect(storage.cleared, 0);
    expect(markerFile().existsSync(), isTrue);
  });

  test('UPDATE of an install that predates the marker: the database exists, nothing is cleared', () async {
    await database.create(recursive: true);
    final storage = _Storage(credentials: true);
    expect(await marker().clearCredentialsOfDeletedInstall(storage), isFalse);
    expect(storage.cleared, 0, reason: 'a signed-in user must stay signed in through an update');
    expect(storage.credentials, isTrue);
    expect(markerFile().existsSync(), isTrue, reason: 'and the marker is written for next time');
  });

  test('a marker that cannot be written: NOTHING is cleared', () async {
    // The support "directory" is a file, so neither it nor the marker can be created.
    await File(support.path).create(recursive: true);
    final storage = _Storage(credentials: true);
    expect(await marker().clearCredentialsOfDeletedInstall(storage), isFalse);
    expect(storage.cleared, 0, reason: 'a wipe that cannot be remembered would repeat on every start');
  });

  test('the marker is written BEFORE the clearing; a failing clear does not throw and does not repeat', () async {
    final storage = _Storage(credentials: true)..clearFails = true;
    expect(await marker().clearCredentialsOfDeletedInstall(storage), isFalse);
    expect(markerFile().existsSync(), isTrue);

    storage.clearFails = false;
    expect(await marker().clearCredentialsOfDeletedInstall(storage), isFalse);
    expect(storage.cleared, 0, reason: 'not retried at every start');
  });

  test('nothing can throw into the start-up (no platform directories in a plain test)', () async {
    // Default directories need path_provider, which is absent here.
    expect(await InstallMarker().clearCredentialsOfDeletedInstall(_Storage(credentials: true)), isFalse);
  });
}
