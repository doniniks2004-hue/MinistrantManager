import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Things the native projects must contain for features written in Dart to
/// work at all, and which fail silently when they do not. Each group reads the
/// project files of ONE platform and is skipped in the tree that has none, so
/// the same file lives in both trees.
void main() {
  final iosPlist = File('ios/Runner/Info.plist');
  final androidManifest = File('android/app/src/main/AndroidManifest.xml');

  group('iOS project', skip: iosPlist.existsSync() ? false : 'no ios/ project in this tree', () {
    final pbxproj = File('ios/Runner.xcodeproj/project.pbxproj');
    final entitlements = File('ios/Runner/Runner.entitlements');
    final privacy = File('ios/Runner/PrivacyInfo.xcprivacy');

    test('the entitlements file is USED by the Runner target in every configuration', () {
      // The file existed for a long time without being referenced by the
      // project, so Universal Links were configured and never applied.
      final text = pbxproj.readAsStringSync();
      final uses = RegExp(r'CODE_SIGN_ENTITLEMENTS = Runner/Runner\.entitlements;').allMatches(text).length;
      expect(uses, 3, reason: 'Debug, Release and Profile of Runner');
      expect(text, contains('Runner.entitlements */ = {isa = PBXFileReference'));
    });

    test('the entitlements declare the Universal Links domain', () {
      expect(entitlements.readAsStringSync(), contains('applinks:app.ministrant.eu'));
    });

    test('the privacy manifest exists, is part of the app bundle, and declares no tracking', () {
      expect(privacy.existsSync(), isTrue);
      final text = pbxproj.readAsStringSync();
      expect(text, contains('PrivacyInfo.xcprivacy in Resources'));
      final manifest = privacy.readAsStringSync();
      expect(manifest, matches(RegExp(r'<key>NSPrivacyTracking</key>\s*<false/>')));
    });

    test('every required-reason API the app itself uses is declared with a reason', () {
      // snapshot_store.dart orders leftover directories by modification time.
      final manifest = privacy.readAsStringSync();
      expect(manifest, contains('NSPrivacyAccessedAPICategoryFileTimestamp'));
      expect(manifest, contains('C617.1'));
    });

    test('App Transport Security allows loopback HTTP and nothing broader', () {
      final plist = iosPlist.readAsStringSync();
      expect(plist, contains('NSAllowsLocalNetworking'));
      expect(plist, contains('<key>127.0.0.1</key>'));
      expect(plist, isNot(contains('NSAllowsArbitraryLoads')), reason: 'never general cleartext');
    });

    test('the camera is described (the QR activation needs it, and the app is rejected without it)', () {
      final plist = iosPlist.readAsStringSync();
      final match = RegExp(r'<key>NSCameraUsageDescription</key>\s*<string>([^<]+)</string>').firstMatch(plist);
      expect(match, isNotNull);
      expect(match!.group(1)!.trim(), isNotEmpty);
    });
  });

  group('Android project', skip: androidManifest.existsSync() ? false : 'no android/ project in this tree', () {
    test('the permissions the app code relies on are declared', () {
      final text = androidManifest.readAsStringSync();
      expect(text, contains('android.permission.INTERNET'));
      expect(text, contains('android.permission.CAMERA'), reason: 'QR activation');
    });

    test('registering the network callback needs ACCESS_NETWORK_STATE', () {
      // Without the permission registerDefaultNetworkCallback throws
      // SecurityException. Required exactly when the native code registers it.
      final activity = File('android/app/src/main/kotlin/eu/ministrant/manager/MainActivity.kt');
      final registers =
          activity.existsSync() && activity.readAsStringSync().contains('registerDefaultNetworkCallback');
      if (registers) {
        expect(androidManifest.readAsStringSync(), contains('android.permission.ACCESS_NETWORK_STATE'));
      }
    });
  });
}
