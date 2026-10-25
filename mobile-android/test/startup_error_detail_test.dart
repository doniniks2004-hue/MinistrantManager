import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/util/startup_error_detail.dart';

void main() {
  test('the Keychain refusing for want of an entitlement is named by its code and status, not its message', () {
    final detail = startupErrorDetail(
      PlatformException(
        code: 'Unexpected security result code',
        message: "Code: -34018, Message: A required entitlement isn't present., http://secret.example/x?token=abc",
      ),
    );
    expect(detail, 'PlatformException(Unexpected security result code -34018)');
    for (final leak in ['secret', 'token', 'http', 'entitlement', '/', '?']) {
      expect(detail, isNot(contains(leak)));
    }
  });

  test('a platform error without a status or a message is still described', () {
    expect(startupErrorDetail(PlatformException(code: 'channel-error')), 'PlatformException(channel-error)');
    expect(startupErrorDetail(PlatformException(code: '')), 'PlatformException()');
  });

  test('any other error is its type and nothing else, whatever its message carries', () {
    expect(startupErrorDetail(StateError('opened /var/mobile/Containers/x/key.db')), 'StateError');
    expect(startupErrorDetail(const FormatException('http://a?b=c')), 'FormatException');
  });

  test('a very long or odd code is cut and cleaned', () {
    final detail = startupErrorDetail(PlatformException(code: 'a/b?c=d${'x' * 200}', message: 'status 12345'));
    expect(detail.length, lessThan(100));
    expect(detail, contains('12345'));
    expect(detail, isNot(contains('/')));
  });
}
