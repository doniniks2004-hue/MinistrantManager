import 'package:sqlite3/common.dart';

/// Iteration 1.1 point 11: encryption-at-rest is isolated behind this
/// interface so the actual cipher implementation can be swapped without
/// touching AppDatabase, SecureStorageService, or any repository code —
/// exactly the boundary requested in review ("wydzielić szyfrowanie za
/// warstwą... żeby implementację... można było kiedyś zmienić bez
/// przebudowy całej warstwy repository").
abstract class CipherEngine {
  /// Applies whatever PRAGMA(s) actually turn on encryption for this
  /// engine, using [encryptionKey]. Called from Drift's `setup:` callback,
  /// i.e. before Drift touches the connection at all.
  void applyCipherPragmas(CommonDatabase rawDb, String encryptionKey);

  /// MANDATORY runtime check (review point 11: "po otwarciu bazy MUSI
  /// istnieć runtime verification, że faktycznie działa silnik
  /// szyfrujący... nie wystarczy samo wykonanie PRAGMA key"). Must throw
  /// [CipherNotActiveException] if the loaded SQLite build does not
  /// actually have the expected cipher extension compiled in — e.g.
  /// because someone accidentally shipped the plain `sqlite3_flutter_libs`
  /// binary instead of the cipher-enabled one. Failing loudly here is far
  /// better than silently persisting plaintext under an "encrypted"
  /// database's name.
  void verifyCipherActive(CommonDatabase rawDb);
}

class CipherNotActiveException implements Exception {
  CipherNotActiveException(this.message);
  final String message;
  @override
  String toString() => 'CipherNotActiveException: $message';
}
