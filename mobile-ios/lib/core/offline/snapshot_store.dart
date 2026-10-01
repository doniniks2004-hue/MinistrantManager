import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'snapshot_manifest.dart';

/// Offline-architecture milestone, P3. On-disk storage for per-page PHP
/// snapshots, matching the architecture decision's layout exactly:
///
/// ```
/// <app support dir>/local-cache/
///   <parish_id>/
///     <user_id>/
///       <page>/
///         snapshot.html
///         assets/
///         manifest.json
/// ```
///
/// Deliberately under the platform's "application support" directory
/// (`path_provider`'s `getApplicationSupportDirectory()`), NOT the
/// temporary-files directory — review round: "Nie wolno polegać
/// wyłącznie na cache WebView... Musimy mieć własny snapshot aplikacji."
/// A store the OS is free to purge under storage pressure would defeat
/// that requirement just as much as relying on WebView's own cache
/// would; application-support storage persists until the app itself (or
/// an uninstall) removes it.
///
/// Isolation (review round point 10/11): every read/write operation
/// requires parish_id AND user_id explicitly — there is no "current
/// user" implicit state inside this class, and no method that can read
/// or write across a parish_id/user_id boundary it wasn't given. Mixing
/// users/parishes would require a CALLER to pass the wrong IDs on
/// purpose; nothing in here infers or caches an "active" identity.
class SnapshotStore {
  Directory? _rootOverride;

  /// Tests pass a temp directory here instead of the real platform
  /// application-support directory.
  SnapshotStore({Directory? rootOverride}) : _rootOverride = rootOverride;

  Future<Directory> _cacheRoot() async {
    final override = _rootOverride;
    if (override != null) return override;
    final supportDir = await getApplicationSupportDirectory();
    return Directory(p.join(supportDir.path, 'local-cache'));
  }

  Future<Directory> _pageDirectory({
    required String parishId,
    required String userId,
    required String pagePath,
  }) async {
    final root = await _cacheRoot();
    return Directory(p.join(
      root.path,
      _sanitizeSegment(parishId),
      _sanitizeSegment(userId),
      _sanitizeSegment(pagePath),
    ));
  }

  /// Returns the directory to point [LocalSnapshotServer.rootDirectory]
  /// at for this page, or null if no COMPLETE snapshot exists (a
  /// missing or unparseable manifest.json means "not ready" — see
  /// [SnapshotManifest.tryFromJson] and this store's own atomic-write
  /// guarantee: a directory with a readable manifest.json is never a
  /// partially-written one).
  Future<Directory?> getPageDirectoryIfReady({
    required String parishId,
    required String userId,
    required String pagePath,
  }) async {
    final dir = await _pageDirectory(parishId: parishId, userId: userId, pagePath: pagePath);
    final manifest = await readManifest(dir);
    if (manifest == null) return null;
    return dir;
  }

  Future<SnapshotManifest?> readManifest(Directory pageDirectory) async {
    final file = File(p.join(pageDirectory.path, 'manifest.json'));
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return SnapshotManifest.tryFromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<SnapshotManifest?> readManifestFor({
    required String parishId,
    required String userId,
    required String pagePath,
  }) async {
    final dir = await _pageDirectory(parishId: parishId, userId: userId, pagePath: pagePath);
    return readManifest(dir);
  }

  /// Atomically replaces whatever snapshot (if any) exists for this
  /// exact (parish, user, page) with the new content — review round:
  /// "Nigdy nie nadpisujemy działającego snapshotu częściowo pobranymi
  /// plikami." Sequence (every step either fully happens or the whole
  /// operation throws and the ORIGINAL snapshot is left completely
  /// untouched, since nothing above has renamed anything into its
  /// place yet):
  ///
  ///  1. Write html + every asset + manifest.json into a fresh,
  ///     uniquely-named temp directory alongside the real page
  ///     directory (same parent -> same filesystem -> the final rename
  ///     below is a real atomic rename, not a cross-filesystem copy).
  ///  2. If a PREVIOUS snapshot directory exists at the real path,
  ///     rename IT out of the way to a unique trash name first — this
  ///     guarantees the final rename target is always fully absent, so
  ///     step 3 never depends on platform-specific "rename onto an
  ///     existing directory" behavior (which dart:io/the underlying OS
  ///     call do not consistently guarantee across platforms).
  ///  3. Rename the temp directory to the real page directory name —
  ///     THIS is the single atomic step a reader can never observe
  ///     half-done: at every instant, the real path either has the old
  ///     complete snapshot or the new complete snapshot, never neither
  ///     and never a partial one.
  ///  4. Best-effort delete the old (now-trashed) directory — failure
  ///     to clean this up does not affect correctness, only leaves an
  ///     orphaned directory that a future cache-eviction pass can still
  ///     find and remove.
  Future<void> writeSnapshot({
    required String parishId,
    required String userId,
    required String pagePath,
    required String html,
    required Map<String, List<int>> assets,
    DateTime? capturedAt,
  }) async {
    final root = await _cacheRoot();
    final parentDir = Directory(p.join(root.path, _sanitizeSegment(parishId), _sanitizeSegment(userId)));
    await parentDir.create(recursive: true);

    final pageSegment = _sanitizeSegment(pagePath);
    final realDir = Directory(p.join(parentDir.path, pageSegment));
    final tempDir = Directory(p.join(parentDir.path, '$pageSegment.tmp-${_randomSuffix()}'));

    await tempDir.create(recursive: true);
    try {
      await File(p.join(tempDir.path, 'snapshot.html')).writeAsString(html);

      for (final entry in assets.entries) {
        final assetFile = File(p.join(tempDir.path, 'assets', entry.key));
        await assetFile.parent.create(recursive: true);
        await assetFile.writeAsBytes(entry.value);
      }

      final manifest = SnapshotManifest(
        parishId: parishId,
        userId: userId,
        path: pagePath,
        capturedAt: capturedAt ?? DateTime.now(),
        resources: assets.keys.map((key) => 'assets/$key').toList(),
      );
      // Written LAST within the temp directory — belt-and-braces on top
      // of the atomic rename below, so that even someone inspecting the
      // temp directory mid-write (which no reader of the REAL path ever
      // can) would see the manifest only once everything else is down.
      await File(p.join(tempDir.path, 'manifest.json')).writeAsString(jsonEncode(manifest.toJson()));

      if (await realDir.exists()) {
        final trashDir = Directory(p.join(parentDir.path, '$pageSegment.trash-${_randomSuffix()}'));
        await realDir.rename(trashDir.path);
        await tempDir.rename(realDir.path);
        await trashDir.delete(recursive: true).catchError((_) {});
      } else {
        await tempDir.rename(realDir.path);
      }
    } catch (_) {
      // The real snapshot (if any) was never touched until the rename
      // above, which either fully succeeded or wasn't reached — the
      // only cleanup needed on any failure is the temp directory itself.
      await tempDir.delete(recursive: true).catchError((_) {});
      rethrow;
    }
  }

  /// Logout (review round point 11/19/21): removes every snapshot for
  /// this one user within this one parish. Never touches installation-
  /// level data (that lives entirely outside `local-cache/`, in
  /// SecureStorageService/AppDatabase) and never touches any OTHER
  /// user's snapshots, including other users within the SAME parish.
  Future<void> clearForUser({required String parishId, required String userId}) async {
    final root = await _cacheRoot();
    final userDir = Directory(p.join(root.path, _sanitizeSegment(parishId), _sanitizeSegment(userId)));
    if (await userDir.exists()) {
      await userDir.delete(recursive: true);
    }
  }

  /// Parish reset/revocation (review round point 13/22): removes EVERY
  /// user's snapshots for this one parish — used when the device's
  /// activation is reset/changed to a different parish, or on
  /// DEVICE_REVOKED/PARISH_DISABLED, so "offline cache" can never be
  /// used to route around either (review round point 22: "Nie może
  /// pozostać możliwość obejścia blokady przez offline cache").
  Future<void> clearForParish({required String parishId}) async {
    final root = await _cacheRoot();
    final parishDir = Directory(p.join(root.path, _sanitizeSegment(parishId)));
    if (await parishDir.exists()) {
      await parishDir.delete(recursive: true);
    }
  }

  /// Removes the entire local-cache tree — every parish, every user.
  /// Not reachable from any normal app flow today; kept for completeness
  /// (e.g. a future "clear all app data" debug/support action) rather
  /// than forcing a caller to reach into `_cacheRoot()` itself.
  Future<void> clearAll() async {
    final root = await _cacheRoot();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  /// Filesystem-safe, human-readable directory-name encoding. NOT a
  /// security boundary by itself (the security boundary is
  /// LocalSnapshotServer's own path-traversal check plus the fact that
  /// every operation here requires an explicit parish_id/user_id) — this
  /// exists purely so an arbitrary legacy URL path or ID string can
  /// never produce an invalid or (via `..`/`/`) structurally-dangerous
  /// directory name. `/public/dashboard.php` -> `public_dashboard.php`.
  static String _sanitizeSegment(String input) {
    final stripped = input.startsWith('/') ? input.substring(1) : input;
    final safe = stripped.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.isEmpty ? '_' : safe;
  }

  static final Random _random = Random();

  static String _randomSuffix() {
    // Collision-avoidance for two near-simultaneous writes of the SAME
    // page, nothing more — never read back or relied on for anything
    // other than being a temporary, soon-discarded directory name.
    return List.generate(8, (_) => _random.nextInt(16).toRadixString(16)).join();
  }
}
