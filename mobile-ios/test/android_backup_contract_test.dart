import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The database, the saved pages and the sign-in state are protected by keys
/// that live in the Android Keystore and are never backed up. If the files are
/// backed up and restored without the keys, the app finds a database it can
/// never open. So nothing is backed up or transferred (Android 11-: allowBackup;
/// Android 12+: data extraction rules for the cloud backup AND the
/// device-to-device transfer).
///
/// Reads the Android project, so the group is skipped in a tree that has none.
void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  final rules = File('android/app/src/main/res/xml/data_extraction_rules.xml');

  group('Android backup', skip: manifest.existsSync() ? false : 'no android/ project in this tree', () {
    test('automatic backup is off', () {
      expect(manifest.readAsStringSync(), contains('android:allowBackup="false"'));
    });

    test('the manifest points at the extraction rules', () {
      expect(manifest.readAsStringSync(), contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
    });

    test('the rules exclude every domain from BOTH the cloud backup and the device transfer', () {
      final text = rules.readAsStringSync();
      for (final section in ['cloud-backup', 'device-transfer']) {
        final match = RegExp('<$section>(.*?)</$section>', dotAll: true).firstMatch(text);
        expect(match, isNotNull, reason: section);
        for (final domain in ['root', 'file', 'database', 'sharedpref', 'external']) {
          expect(match!.group(1), contains('<exclude domain="$domain" path="." />'), reason: '$section / $domain');
        }
        expect(match!.group(1), isNot(contains('<include')), reason: '$section includes nothing');
      }
    });
  });
}
