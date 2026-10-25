import 'package:flutter/services.dart' show PlatformException;

/// A short description of why the app could not start, SAFE to show and to write
/// to a log or a marker file: the type of the error and, for an error from the
/// platform, its code and the numeric status in its message (for the Keychain,
/// for instance `-34018`, "a required entitlement is not present"). Never the
/// message itself: an exception's message can carry paths, addresses or values.
String startupErrorDetail(Object error) {
  if (error is PlatformException) {
    final code = error.code.replaceAll(RegExp(r'[^A-Za-z0-9 _\-]'), '').trim();
    final status = RegExp(r'-?\d{3,6}').firstMatch(error.message ?? '')?.group(0);
    final shortCode = code.length > 60 ? code.substring(0, 60) : code;
    return 'PlatformException(${[shortCode, if (status != null) status].where((p) => p.isNotEmpty).join(' ')})';
  }
  return error.runtimeType.toString();
}
