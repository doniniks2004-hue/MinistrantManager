import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/snapshot_crypto_vector.dart';
import 'package:ministrant_manager/core/offline/snapshot_encryptor.dart';
import 'package:ministrant_manager/selftest/platform_selftest.dart';
import 'package:ministrant_manager/selftest/selftest_report.dart';

/// The self-test app is meant to be run on a simulator or a phone, where it is
/// the only thing that exercises the real native crypto and a real WebView. But
/// its widget-free half is plain Dart over real sockets and a real file system,
/// so it is run HERE too: the harness is checked on every change, before a
/// simulator is the first thing to run it.
void main() {
  group('SelfTestReport', () {
    SelfTestReport report() => SelfTestReport(mode: 'full', run: 1, platform: 'test');

    test('a run is a pass only when it finished and nothing failed', () {
      final r = report()..add(const CheckResult('a', CheckStatus.pass, 1, ''));
      expect(r.ok, isFalse, reason: 'not finished: a run cut short is not a pass');
      r.done = true;
      expect(r.ok, isTrue);
      r.add(const CheckResult('b', CheckStatus.fail, 1, 'x'));
      expect(r.ok, isFalse);
    });

    test('an informational result never fails a run and is never counted as a pass', () {
      final r = report()
        ..add(const CheckResult('a', CheckStatus.pass, 1, ''))
        ..add(const CheckResult('b', CheckStatus.info, 1, 'observation'))
        ..done = true;
      expect(r.ok, isTrue);
      expect(r.passed, 1);
      expect(r.informational, 1);
    });

    test('the JSON a CI job reads carries the verdict, the counts and every check', () {
      final r = report()
        ..add(const CheckResult('a', CheckStatus.pass, 3, 'fine'))
        ..marks['painted_ms'] = 700
        ..done = true;
      final json = r.toJson();
      expect(json['ok'], isTrue);
      expect(json['mode'], 'full');
      expect(json['marks'], {'painted_ms': 700});
      expect((json['checks'] as List).single, {'name': 'a', 'status': 'pass', 'ms': 3, 'detail': 'fine'});
    });
  });

  group('PlatformSelfTest core checks on this machine', () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp('mm_selftest_'));
    tearDown(() async => dir.delete(recursive: true));

    test('the checks that need no phone all pass, and the ones that do are observations, not passes', () async {
      SnapshotEncryptor.debugResetNative();
      final report = SelfTestReport(mode: 'full', run: 1, platform: 'host');
      final lines = <String>[];
      final server = await PlatformSelfTest(workDirectory: dir).runCore(report, log: lines.add);
      addTearDown(server.stop);
      report.done = true;

      final byName = {for (final c in report.checks) c.name: c};
      expect(report.failed, 0, reason: report.checks.where((c) => c.status == CheckStatus.fail).map((c) => '${c.name}: ${c.detail}').join('\n'));

      for (final name in [
        'crypto.openssl_vector_dart_opens',
        'crypto.openssl_vector_refused_under_another_key',
        'crypto.tampered_payload_refused',
        'store.encrypted_roundtrip',
        'server.loopback_http',
        'server.security_headers',
        'server.second_request_from_memory',
        'server.listener_recovery',
      ]) {
        expect(byName[name]?.status, CheckStatus.pass, reason: '$name: ${byName[name]?.detail}');
      }
      // No native crypto and no keychain here: said so, not passed.
      expect(byName['crypto.platform_verified']?.status, CheckStatus.info);
      expect(byName['crypto.interop_dart_and_platform']?.status, CheckStatus.info);
      expect(byName['keychain.secure_storage']?.status, CheckStatus.info);
      expect(lines.every((l) => l.startsWith('MM_SELFTEST ')), isTrue);
    });

    test('the page it saves is kept on disk for the next run to open', () async {
      final test = PlatformSelfTest(workDirectory: dir);
      final server = await test.runCore(SelfTestReport(mode: 'full', run: 1, platform: 'host'));
      addTearDown(server.stop);
      await server.stop();

      // A "new process": a fresh encryptor and store over the same folder.
      final next = PlatformSelfTest(workDirectory: dir);
      final found = await next.store.getPageDirectoryIfReady(
        parishId: PlatformSelfTest.parishId,
        userId: PlatformSelfTest.userId,
        pagePath: PlatformSelfTest.pagePath,
      );
      expect(found, isNotNull);
    });

    test('REGRESSION: the OpenSSL vector opens under ITS key and is refused under the harness key', () {
      // The harness once opened the vector with the key the saved page uses and got
      // InvalidCipherTextException; that was correct, the vector was sealed with
      // another key. The two keys are different, on purpose.
      expect(PlatformSelfTest.hexKey, isNot(snapshotVectorKeyHex));
      final sealed = snapshotVectorBytes(snapshotVectorSealedHex);
      final plain = snapshotVectorBytes(snapshotVectorPlainHex);
      expect(SnapshotEncryptor(hexKey: snapshotVectorKeyHex).decryptBytes(sealed), plain);
      expect(() => SnapshotEncryptor(hexKey: PlatformSelfTest.hexKey).decryptBytes(sealed), throwsA(anything));
    });

    test('the stand-in page has the sizes of a real dashboard', () {
      expect(PlatformSelfTest.html.length, inInclusiveRange(56000, 57000));
      expect(PlatformSelfTest.css.length, inInclusiveRange(22000, 22200));
      expect(PlatformSelfTest.js.length, inInclusiveRange(20000, 20200));
    });

    test('a check that throws is recorded as a failure, and as an observation when informational', () async {
      final test = PlatformSelfTest(workDirectory: dir);
      final report = SelfTestReport(mode: 'full', run: 1, platform: 'host');
      await test.check(report, 'boom', () async => throw StateError('nope'));
      await test.check(report, 'boom-info', () async => throw StateError('nope'), informational: true);
      expect(report.checks.map((c) => c.status), [CheckStatus.fail, CheckStatus.info]);
      expect(report.checks.first.detail, contains('nope'));
    });
  });
}
