import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/features/revocation/wipe_marker.dart';

/// The file marker (the fallback place) and the combination of places. (Written without being able
/// to run Flutter here: not executed.)

class _Place implements WipeMarkerStore {
  String? value;
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;

  @override
  Future<String?> read() async {
    if (failRead) throw StateError('unreadable');
    return value;
  }

  @override
  Future<void> write(String v) async {
    if (failWrite) throw StateError('unwritable');
    value = v;
  }

  @override
  Future<void> delete() async {
    if (failDelete) throw StateError('undeletable');
    value = null;
  }
}

void main() {
  group('FileWipeMarkerStore', () {
    late Directory root;
    late FileWipeMarkerStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('wipe_marker_test');
      store = FileWipeMarkerStore(directory: () async => Directory('${root.path}/support'));
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('nothing there reads as null (and the directory need not exist)', () async {
      expect(await store.read(), isNull);
    });

    test('writes (creating the directory), reads back, deletes', () async {
      await store.write('{"v":1}');
      expect(await store.read(), '{"v":1}');
      await store.delete();
      expect(await store.read(), isNull);
    });

    test('deleting what is not there is not an error', () async {
      await store.delete();
      await store.delete();
    });

    test('writing again replaces it', () async {
      await store.write('a');
      await store.write('b');
      expect(await store.read(), 'b');
    });

    test('a directory where the file should be is not a marker, and cannot be written over', () async {
      await Directory('${root.path}/support/${FileWipeMarkerStore.fileName}').create(recursive: true);
      expect(await store.read(), isNull);
      await expectLater(store.write('x'), throwsA(anything));
    });

    test('it throws when it cannot write', () async {
      final blocked = FileWipeMarkerStore(directory: () async => Directory('${root.path}/file-not-dir/x'));
      await File('${root.path}/file-not-dir').writeAsString('i am a file');
      await expectLater(blocked.write('x'), throwsA(anything));
    });

    test('what it holds is the marker and nothing else: no token, key or URL', () async {
      final text = WipeMarker(reason: WipeReason.revoked, parishId: 'p1', startedAt: DateTime.utc(2026)).encode();
      await store.write(text);
      final raw = (await store.read())!.toLowerCase();
      for (final word in ['token', 'key', 'http', 'cookie', 'password']) {
        expect(raw, isNot(contains(word)), reason: word);
      }
    });
  });

  group('WipeMarkers (the places taken together)', () {
    late _Place a;
    late _Place b;
    late WipeMarkers markers;
    setUp(() {
      a = _Place();
      b = _Place();
      markers = WipeMarkers([a, b]);
    });

    test('write: true when stored in either place, false only when in none', () async {
      expect(await markers.write('m'), isTrue);
      expect(a.value, 'm');
      expect(b.value, 'm');
      a.value = b.value = null;
      a.failWrite = true;
      expect(await markers.write('m'), isTrue);
      expect(b.value, 'm');
      b.value = null;
      b.failWrite = true;
      expect(await markers.write('m'), isFalse, reason: 'nothing was stored: no promise may be made');
    });

    test('read: a marker from either place; absent everywhere is null', () async {
      expect(await markers.read(), isNull);
      b.value = 'm';
      expect(await markers.read(), 'm');
      a.value = 'n';
      expect(await markers.read(), 'n', reason: 'the first place that has one');
    });

    test('read: a place that cannot be read does not hide a marker in the other', () async {
      a.failRead = true;
      b.value = 'm';
      expect(await markers.read(), 'm');
    });

    test('read: no marker found AND a place that could not be read is not "no marker": it throws', () async {
      a.failRead = true;
      await expectLater(markers.read(), throwsA(isA<StateError>()));
    });

    test('delete: clears every place, and throws if one could not be cleared (the others ARE cleared)', () async {
      a.value = b.value = 'm';
      b.failDelete = true;
      await expectLater(markers.delete(), throwsA(isA<StateError>()));
      expect(a.value, isNull);
      expect(b.value, 'm');
    });
  });
}
