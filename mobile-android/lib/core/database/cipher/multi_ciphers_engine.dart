import 'package:sqlite3/sqlite3.dart';
import 'cipher_engine.dart';

/// The ONLY cipher engine in this codebase (review round 2, point 1:
/// `sqlcipher_flutter_libs` and its fallback engine were removed
/// entirely — no production install base exists yet to migrate, so there
/// is nothing to keep a legacy path for).
///
/// STATUS: **IMPLEMENTED / NOT VERIFIED ON REAL DEVICE.** The pragma
/// sequence, the CipherEngine abstraction, and the mandatory
/// verifyCipherActive() guard are implemented and structurally correct
/// per SQLite3MultipleCiphers' documented interface. None of it has run
/// against a real compiled binary or a real device/emulator — this
/// sandbox has no Flutter/Dart toolchain and no pub.dev access (see
/// docs/ENCRYPTION.md for the exact four-point checklist that moves this
/// to `VERIFIED`, and for what remains — confirming the
/// `hooks.user_defines.sqlite3.source: sqlite3mc` entry in `pubspec.yaml`
/// against the live registry and actually building with it — still needs
/// a human with pub.dev access to finish).
class MultiCiphersEngine implements CipherEngine {
  const MultiCiphersEngine({this.cipherName = 'chacha20'});

  /// Which SQLite3MultipleCiphers scheme to select. `chacha20` is that
  /// extension's own modern default; kept configurable (rather than
  /// inlined into the pragma strings below) so a future audit/compliance
  /// requirement to pin a specific scheme touches one constructor
  /// argument, not every call site.
  final String cipherName;

  @override
  void applyCipherPragmas(CommonDatabase rawDb, String encryptionKey) {
    // SQLite3MultipleCiphers' documented pragma sequence: select the
    // cipher scheme BEFORE setting the key (order matters — `cipher`
    // must be set on a still-unkeyed, freshly-opened connection).
    rawDb.execute("PRAGMA cipher = '$cipherName';");
    rawDb.execute("PRAGMA key = '$encryptionKey';");
  }

  @override
  void verifyCipherActive(CommonDatabase rawDb) {
    // Review round 2, point 1 fix: `PRAGMA cipher_version;` merely
    // proves SOME cipher extension responded — it doesn't confirm which
    // one, or that the specific scheme we asked for is the one actually
    // active. `PRAGMA cipher;` (no argument) is SQLite3MultipleCiphers'
    // own read-back of the CURRENTLY SELECTED cipher for this
    // connection — comparing it against the exact scheme we just set is
    // the unambiguous check requested: it fails if the extension is
    // absent (empty/no rows — unknown pragmas are silently ignored by
    // plain SQLite) AND it fails if some other cipher extension is
    // present but answering a different scheme name than we configured.
    final result = rawDb.select('PRAGMA cipher;');
    final activeCipher = result.isNotEmpty ? result.first.values.firstOrNull?.toString() : null;

    if (activeCipher == null || activeCipher.isEmpty) {
      throw CipherNotActiveException(
        'PRAGMA cipher returned nothing — no SQLite3MultipleCiphers-compatible '
        'extension is active in the loaded sqlite3 binary. Refusing to open the '
        'database: it would be PLAINTEXT. See docs/ENCRYPTION.md.',
      );
    }

    if (activeCipher.toLowerCase() != cipherName.toLowerCase()) {
      throw CipherNotActiveException(
        'PRAGMA cipher reports "$activeCipher", not the expected "$cipherName". '
        'Either a different cipher extension is loaded, or the PRAGMA cipher = '
        '\'$cipherName\'; call above was silently ignored. Refusing to open the '
        'database rather than proceed with an unconfirmed encryption scheme.',
      );
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
