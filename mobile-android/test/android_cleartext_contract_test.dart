import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Saved pages are shown from a tiny HTTP server on the phone itself
/// (http://127.0.0.1:PORT). Android 9+ refuses plain HTTP unless the app's
/// network security config allows it, and a WebView that cannot load the
/// saved copy shows nothing: the whole offline mode silently stops working.
/// The allowance must exist, and must be exactly as narrow as that need —
/// the loopback addresses only, never general cleartext.
///
/// (Reads the Android project files, so it runs where they exist; the iOS
/// tree has none. The server-side half is checked in every tree.)
void main() {
  final manifestFile = File('android/app/src/main/AndroidManifest.xml');
  final configFile = File(
    'android/app/src/main/res/xml/network_security_config.xml',
  );
  final hasAndroidProject = manifestFile.existsSync();

  group(
    'Android network security config',
    skip: hasAndroidProject ? false : 'no android/ project in this tree',
    () {
      test('the manifest points at the config', () {
        expect(
          manifestFile.readAsStringSync(),
          contains('android:networkSecurityConfig="@xml/network_security_config"'),
        );
      });

      test('no manifest (main, debug, profile) turns cleartext on for everything', () {
        final manifests = Directory('android/app/src')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('AndroidManifest.xml'));
        expect(manifests, isNotEmpty);
        for (final file in manifests) {
          expect(
            file.readAsStringSync(),
            isNot(contains('usesCleartextTraffic="true"')),
            reason: file.path,
          );
        }
      });

      test('cleartext is off by default', () {
        expect(
          configFile.readAsStringSync(),
          matches(RegExp(r'<base-config\s+cleartextTrafficPermitted="false"')),
        );
      });

      test('the ONLY cleartext allowance is the loopback address, without subdomains', () {
        final xml = configFile.readAsStringSync();
        final allowed = RegExp(
          r'<domain-config\s+cleartextTrafficPermitted="true">(.*?)</domain-config>',
          dotAll: true,
        ).allMatches(xml);
        expect(allowed, isNotEmpty, reason: 'saved pages could not be loaded');

        final domains = <String>{};
        for (final block in allowed) {
          for (final d in RegExp(
            r'<domain\s+([^>]*)>([^<]+)</domain>',
          ).allMatches(block.group(1)!)) {
            expect(d.group(1), contains('includeSubdomains="false"'));
            domains.add(d.group(2)!.trim());
          }
        }
        expect(domains, {'127.0.0.1', 'localhost'});
      });
    },
  );

  group('the local snapshot server stays on the loopback address', () {
    final source = File('lib/core/offline/local_snapshot_server.dart');

    test('it binds to loopback only, so nothing else can reach it', () {
      expect(
        source.readAsStringSync(),
        contains('HttpServer.bind(InternetAddress.loopbackIPv4'),
      );
      expect(source.readAsStringSync(), isNot(contains('anyIPv4')));
      expect(source.readAsStringSync(), isNot(contains('anyIPv6')));
    });

    test('it hands out 127.0.0.1 URLs, the host the config allows', () {
      expect(source.readAsStringSync(), contains("'http://127.0.0.1:\$port/"));
    });
  });
}
