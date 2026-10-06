import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/offline/page_identity.dart';
import 'package:ministrant_manager/core/network/parish_server_url.dart';

void main() {
  test('ranking and dashboard keep distinct identities, including filters', () {
    expect(
      snapshotPagePath(
        Uri.parse(
          'https://szarlej.ministrant.eu/public/ranking.php?month=10#top',
        ),
      ),
      '/public/ranking.php?month=10',
    );
    expect(
      snapshotPagePath(Uri.parse('/public/dashboard.php')),
      '/public/dashboard.php',
    );
  });
  test('auth pages and credential-bearing URLs are never captured', () {
    for (final path in [
      '/public/mobile_handoff.php?ticket=abc',
      '/public/login.php',
      '/public/logout.php',
      '/public/ranking.php?token=secret',
    ]) {
      expect(snapshotPagePath(Uri.parse(path)), isNull);
    }
    expect(isLogoutPath(Uri.parse('/public/logout.php')), isTrue);
    expect(isLogoutPath(Uri.parse('/public/logout_statistics.php')), isFalse);
  });
  test('repair duplicate HTTPS prefix and normalize a trailing slash', () {
    expect(
      normalizeParishServerUrl(' https://https://szarlej.ministrant.eu/ '),
      'https://szarlej.ministrant.eu',
    );
  });
  test(
    'reject insecure or misleading parish URLs before storing credentials',
    () {
      for (final url in [
        'http://szarlej.ministrant.eu',
        'https://szarlej.ministrant.eu.evil.test',
        'https://evilministrant.eu',
        'https://user@szarlej.ministrant.eu',
        'https://szarlej.ministrant.eu:444',
        'https://app.ministrant.eu',
        'https://szarlej.ministrant.eu/path',
        'https://szarlej.ministrant.eu?token=x',
      ]) {
        expect(() => normalizeParishServerUrl(url), throwsFormatException);
      }
    },
  );
}
