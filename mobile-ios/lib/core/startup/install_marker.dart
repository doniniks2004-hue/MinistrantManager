import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../secure/secure_storage_service.dart';

/// Credentials that outlived their app.
///
/// On iOS the Keychain survives an uninstall; the app's own files do not. A
/// reinstalled app therefore found a device token and a user session for a
/// database that no longer exists, and an encryption key for files that are
/// gone. The state looked "activated" and was not usable.
///
/// A small marker file in the application support directory is deleted with
/// the app, so its absence together with an absent database means "these
/// files are new". It is deliberately cautious, because the cost of a wrong
/// guess is a signed-out user:
///  * the database exists, so this is an UPDATE of an install that predates
///    the marker: the marker is written and NOTHING is cleared;
///  * the marker cannot be written: NOTHING is cleared (a wipe that cannot be
///    remembered would repeat on every start);
///  * the marker is written BEFORE anything is cleared, never after;
///  * nothing here can throw into the start-up.
class InstallMarker {
  InstallMarker({Directory? supportDirectory, File? databaseFile})
    : _supportDirectory = supportDirectory,
      _databaseFile = databaseFile;

  final Directory? _supportDirectory;
  final File? _databaseFile;

  static const _markerName = 'install_marker';

  /// Returns whether credentials of a deleted install were cleared.
  Future<bool> clearCredentialsOfDeletedInstall(SecureStorageService storage) async {
    try {
      final support = _supportDirectory ?? await getApplicationSupportDirectory();
      final marker = File(p.join(support.path, _markerName));
      if (await marker.exists()) return false;

      final database = _databaseFile ?? await _defaultDatabaseFile();
      final databaseExists = await database.exists();

      // Written first, and if it cannot be written nothing else happens.
      try {
        await support.create(recursive: true);
        await marker.writeAsString('1', flush: true);
      } catch (_) {
        return false;
      }

      if (databaseExists) return false; // an update, not a new install
      if (!await storage.hasCredentials) return false; // nothing left behind

      await storage.clearAfterDeletedInstall();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<File> _defaultDatabaseFile() async {
    // The same place AppDatabase opens it (app_database.dart, _databaseFile).
    final folder = await getApplicationDocumentsDirectory();
    return File(p.join(folder.path, 'ministrant_manager.sqlite'));
  }
}
