import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/util/log_safe.dart';

void main() {
  group('describeUrlForLog never lets a secret into a log', () {
    test('the saved copy: the access token and the port are dropped', () {
      final text = describeUrlForLog('http://127.0.0.1:43521/AbCdEf0123456789AbCdEf0123456789/assets/public/css/style.css');
      expect(text, 'copy:/assets/public/css/style.css');
      expect(text, isNot(contains('43521')));
      expect(text, isNot(contains('AbCdEf')));
    });

    test('the handoff ticket (a query) is dropped', () {
      final text = describeUrlForLog('https://szarlej.ministrant.eu/public/mobile_handoff.php?ticket=0123456789abcdef0123456789abcdef0123456789abcdef');
      expect(text, 'https://szarlej.ministrant.eu/public/mobile_handoff.php');
      expect(text, isNot(contains('ticket')));
      expect(text, isNot(contains('?')));
    });

    test('a fragment and credentials in the address are dropped', () {
      final text = describeUrlForLog('https://user:hunter2@szarlej.ministrant.eu/public/a.php#secret');
      expect(text, 'https://szarlej.ministrant.eu/public/a.php');
      expect(text, isNot(contains('hunter2')));
      expect(text, isNot(contains('secret')));
    });

    test('a long run of hex digits is masked wherever it appears, even in a path', () {
      final text = describeUrlForLog('https://h.example/public/0123456789abcdef0123456789abcdef/page.php');
      expect(text, contains('<hex>'));
      expect(text, isNot(contains('0123456789abcdef0123')));
    });

    test('the root of the copy, and a copy with only a token', () {
      expect(describeUrlForLog('http://127.0.0.1:1/tok/'), 'copy:/');
      expect(describeUrlForLog('http://127.0.0.1:1/tok'), 'copy:/');
    });

    test('nothing, rubbish, and an address with no scheme', () {
      expect(describeUrlForLog(null), '<none>');
      expect(describeUrlForLog('::::'), '<unparseable>');
      expect(describeUrlForLog('/public/a.php'), '<unparseable>');
    });

    test('a very long path is cut', () {
      final text = describeUrlForLog('https://h.example/${'p' * 400}');
      expect(text.length, lessThanOrEqualTo(120));
      expect(text, endsWith('...'));
    });
  });
}
