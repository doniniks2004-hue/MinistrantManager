import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'snapshot_encryptor.dart';

/// Offline-architecture milestone, P2. A local-only, read-only static
/// file HTTP server that the app's WebView loads snapshot pages from
/// when offline — see the project's own architecture decision:
/// "Wybieramy lokalny HTTP server na 127.0.0.1, a nie `file://` ani
/// `loadHtmlString()`." This is deliberately the ONLY thing this class
/// does: serve files that already exist on disk under [rootDirectory].
/// It never executes PHP, never proxies anywhere, and never accepts
/// writes.
///
/// Security properties (all of these are REQUIREMENTS, not incidental):
/// - Binds to [InternetAddress.loopbackIPv4] ONLY — never reachable from
///   LAN, never `0.0.0.0`.
/// - Random OS-assigned port (`bind(..., 0)`) — never a fixed, guessable
///   port.
/// - GET/HEAD only — anything else (POST, PUT, DELETE, ...) is 405
///   without touching the filesystem at all.
/// - Every resolved path is checked to still be INSIDE [rootDirectory]
///   after normalization — `..` segments, encoded traversal attempts,
///   and absolute-looking request paths can never escape root. A
///   request that fails this check is 404, indistinguishable from a
///   request for a file that simply doesn't exist (never a distinct
///   "forbidden" response that would confirm the path was understood).
/// - 404 for anything not found, anything outside root, and anything
///   requested while no [rootDirectory] is set yet.
/// - No directory listing — a request that resolves to a directory is
///   404, not an index.
///
/// [rootDirectory] is intentionally mutable and re-read on EVERY request
/// rather than captured once — review round: a snapshot "musi być
/// związany co najmniej z parish_id, user_id" and must never mix across
/// a user/parish switch. Swapping this field (e.g. on logout or parish
/// change) takes effect for the very next request with no server
/// restart and no port change, so the WebView's already-open connection
/// doesn't need to be torn down just to point it at a different
/// snapshot root — though the caller is still responsible for actually
/// navigating the WebView away from the old user/parish's pages at that
/// point; this class only controls what the filesystem underneath can
/// ever answer with.
class LocalSnapshotServer {
  LocalSnapshotServer({
    required this.encryptor,
    this.cacheLimitBytes = 8 * 1024 * 1024,
    Future<bool> Function(int port)? healthProbe,
  }) : _healthProbe = healthProbe ?? _accepts;

  /// A real loopback connection by default; replaceable so the repair logic can
  /// be tested without making the operating system close a socket.
  final Future<bool> Function(int port) _healthProbe;

  // ---- is it SERVING right now? ----------------------------------------------
  int _activeRequests = 0;
  DateTime? _lastRequestAt;

  /// The listener's stream ended while this server still believed it was the
  /// current one: the socket was closed from outside (the system reclaiming it).
  /// Said by the stream itself, at once, with no connection attempt at all.
  bool _listenerClosed = false;

  /// How long ONE health probe may take, and how many are made. The repair is
  /// part of building the saved view, which has 1.5 s in all (the offline plan
  /// budget) and is reported as "no saved copy" when it overruns: so the whole
  /// check must cost a fraction of that, whatever the platform does with a
  /// connection to a dead port (Linux and Darwin refuse at once; Windows can take
  /// a second or more to refuse). The probe is bounded here, not trusted to bound
  /// itself.
  static const _probeTimeout = Duration(milliseconds: 400);
  static const _probeAttempts = 2;
  /// A listener that answered a request a moment ago, or is answering one now,
  /// is not dead, whatever one slow probe says.
  static const _recentlyServed = Duration(seconds: 10);

  bool get _servedRecently {
    if (_activeRequests > 0) return true;
    final last = _lastRequestAt;
    return last != null && DateTime.now().difference(last) < _recentlyServed;
  }

  /// Offline-architecture milestone, P8.2: every file under
  /// [rootDirectory] is SnapshotStore-encrypted — this MUST be
  /// constructed with the exact same key (via SecureStorageService's
  /// `getOrCreateSnapshotEncryptionKey()`) that SnapshotStore itself
  /// used to write those files, or every request here will simply fail
  /// to decrypt (caught by the existing catch-all below, same as any
  /// other unexpected per-request error — never a crash, just a 500).
  final SnapshotEncryptor encryptor;

  HttpServer? _server;
  int? _boundPort;

  /// Debug-only diagnostics (the coordinator wires its own trace here). Gets
  /// one line per served file: what it was, whether it came from memory, and
  /// what the read and the decryption cost.
  void Function(String message)? trace;

  // ---- decrypted pages, kept in memory ----------------------------------------
  //
  // Every file of a saved page is encrypted on disk and was decrypted AGAIN
  // for every request, on the isolate that runs the interface: ~260 KB for a
  // dashboard (page 56, stylesheet 22, script 21, logo 158), repeated by every
  // retry, every reload, every return to the page. A retry (which the screen
  // makes on purpose after a failed first opening) therefore redid all the
  // work the failed attempt had already done.
  //
  // Now: decrypted once per file version, off the interface's isolate, and kept
  // (PLAINTEXT, in memory only) up to [_cacheLimitBytes]. A file counts as the
  // same version only while its size and modification time are unchanged, and a
  // file that no longer exists is never served (the request is answered 404
  // before the cache is looked at), so a snapshot that was replaced or deleted
  // (logout, revocation) cannot be served from memory. The cache is emptied
  // when the root is cleared (sign-out, lease expiry, revoked) and on stop().
  // The page is shown in the WebView, in memory, the moment it is opened, so
  // keeping its bytes for a while does not widen what is exposed.
  /// How much plaintext may be kept (8 MB: a few dozen pages like the dashboard).
  final int cacheLimitBytes;
  final _plain = <String, _Plain>{}; // insertion order == least recently used first
  final _decrypting = <String, Future<List<int>>>{};
  int _plainBytes = 0;

  /// Bumped every time the cache is emptied. A decryption that was already
  /// running when that happened (sign-out, revocation) must not put its result
  /// back afterwards.
  int _cacheEpoch = 0;

  /// Whether this file's plaintext is in memory (tests, diagnostics).
  bool hasDecrypted(File file) => _plain.containsKey(_keyOf(file));

  static String _keyOf(File file) => p.normalize(file.absolute.path);

  void clearDecrypted() {
    _cacheEpoch++;
    _plain.clear();
    _plainBytes = 0;
  }
  Directory? _rootDirectory;
  String _accessToken = '';
  Directory? get rootDirectory => _rootDirectory;
  set rootDirectory(Directory? root) {
    // Sign-out, lease expiry, revocation: nothing decrypted may outlive it.
    if (root == null) clearDecrypted();
    _rootDirectory = root;
    final random = Random.secure();
    _accessToken = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Uri urlFor(String path) {
    if (port == null) throw StateError('Snapshot server not ready.');
    return Uri.parse(
      'http://127.0.0.1:$port/$_accessToken/${path.replaceFirst(RegExp(r"^/"), "")}',
    );
  }

  bool ownsUrl(Uri uri) =>
      uri.scheme == 'http' &&
      uri.host == '127.0.0.1' &&
      uri.port == port &&
      uri.path.startsWith('/$_accessToken/');

  int? get port => _boundPort;
  bool get isRunning => _server != null;

  /// Starts the server if not already running and returns the port it's
  /// listening on. Calling this again while already running is a no-op
  /// that just returns the existing port — callers don't need to track
  /// "did I already start this" themselves.
  Future<int> start() {
    final existing = _server;
    if (existing != null) return Future.value(_boundPort!);
    // Concurrent callers share ONE bind. Without this, two calls made before
    // the first bind finished both saw "not running", both bound a port, the
    // second overwrote _server and the first server was orphaned on a port
    // nobody knew — and a URL built from either could point at the wrong one.
    return _starting ??= _bind().whenComplete(() {
      // Block body: whenComplete would wait on a returned Future.
      _starting = null;
    });
  }

  Future<int>? _starting;

  /// The port, with the guarantee that the listener ACTUALLY accepts
  /// connections right now.
  ///
  /// start() trusts that a server it started is still listening. iOS suspends
  /// a backgrounded app and may reclaim its sockets: after the app comes back
  /// the object is still there ([isRunning] is true) while nothing answers on
  /// its port, and every page loaded from it fails. A loopback connection
  /// costs a millisecond; if it is refused the listener is replaced (a new
  /// port; every URL is built from the port at planning time, so nothing
  /// else needs to know).
  Future<int> ensureHealthy() {
    // One check-and-repair at a time, shared by every caller: two callers
    // that each found the socket dead and each called stop() + start() would
    // stop one another's fresh server.
    return _repairing ??= _checkAndRepair().whenComplete(() {
      _repairing = null;
    });
  }

  Future<int>? _repairing;

  Future<int> _checkAndRepair() async {
    final starting = _starting;
    if (starting != null) return starting;
    final current = _server;
    if (current == null) return start();
    final port = _boundPort;
    if (port == null || _listenerClosed) {
      // Closed from outside, and the stream says so: no probe needed, none made.
      if (_listenerClosed) trace?.call('offline-serve: the listener was closed from outside; replacing it');
      await stop();
      return start();
    }
    // The repair is destructive: stop() closes the listener under whatever page
    // is loading from it and forgets its address. A loopback connect that is
    // merely SLOW (the emulator busy decrypting, rendering, saving) must not be
    // taken for a dead socket:
    //  - a server that is serving, or has served within the last seconds, is
    //    alive by definition and is left alone;
    //  - otherwise the probe is tried twice, the second time with more patience,
    //    and only two failures in a row count.
    for (var attempt = 0; attempt < _probeAttempts; attempt++) {
      if (_servedRecently) return port;
      final alive = await _healthProbe(port).timeout(_probeTimeout, onTimeout: () => false);
      if (alive) return port;
    }
    trace?.call('offline-serve: $_probeAttempts probes of ${_probeTimeout.inMilliseconds} ms failed; replacing the listener');
    await stop();
    return start();
  }

  static Future<bool> _accepts(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: _probeTimeout,
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Closes the underlying listener WITHOUT forgetting it, which is what the
  /// operating system does to a suspended app's sockets. For tests only.
  Future<void> debugKillListenerForTest() async {
    await _server?.close(force: true);
    // The stream reports its end a moment after close() returns.
    for (var i = 0; i < 40 && !_listenerClosed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<int> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _boundPort = server.port;
    _listenerClosed = false;
    server.listen(
      (request) async {
        _activeRequests++;
        _lastRequestAt = DateTime.now();
        try {
          await _handleRequest(request);
        } finally {
          _activeRequests--;
          _lastRequestAt = DateTime.now();
        }
      },
      onDone: () {
        // Our own stop() clears _server BEFORE it closes the listener, so this
        // only fires for a listener that was closed behind our back.
        if (identical(_server, server)) _listenerClosed = true;
      },
      onError: (_) {
        // A single malformed connection must never bring the whole
        // server down — dart:io's own listen-level error, distinct from
        // the try/catch inside _handleRequest which covers per-request
        // failures once a request object actually exists.
      },
    );
    return server.port;
  }

  Future<void> stop() async {
    // A start still binding must finish first, or its server would outlive
    // this stop() and be left running.
    final pending = _starting;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    final server = _server;
    _server = null;
    _boundPort = null;
    rootDirectory = null;
    clearDecrypted();
    await server?.close(force: true);
  }

  /// Returns the plaintext of [file], decrypting it at most once per version
  /// of the file and never on the interface's isolate. Concurrent requests for
  /// the same file share one decryption. Returns null if the file is gone.
  /// [base] is the directory of the page the file belongs to: where the file
  /// lives INSIDE its page is part of what a public resource's checksum covers.
  Future<List<int>?> _plaintextOf(File file, Directory base) async {
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) return null;

    final key = _keyOf(file);
    final cached = _plain.remove(key);
    if (cached != null && cached.modified == stat.modified && cached.length == stat.size) {
      _plain[key] = cached; // most recently used
      trace?.call('offline-serve: ${p.basename(file.path)} ${stat.size}B memory');
      return cached.bytes;
    }
    if (cached != null) _plainBytes -= cached.bytes.length; // an older version

    final flightKey = '$key|${stat.modified.microsecondsSinceEpoch}|${stat.size}';
    return _decrypting[flightKey] ??= _decrypt(file, stat, base).whenComplete(() {
      _decrypting.remove(flightKey);
    });
  }

  Future<List<int>> _decrypt(File file, FileStat stat, Directory base) async {
    final epoch = _cacheEpoch;
    final watch = Stopwatch()..start();
    final stored = await file.readAsBytes();
    final readMs = watch.elapsedMilliseconds;

    // A public resource (stylesheet, script, image) is checked, not decrypted:
    // a hash, not a cipher. A file that claims that format and does not verify
    // is NOT trusted: it falls through to the decryption below, which refuses it
    // (a legacy file that merely starts with the same four bytes decrypts fine).
    List<int>? plain;
    var how = 'decrypted';
    if (encryptor.isPublicFormat(stored)) {
      plain = encryptor.openPublic(_labelWithin(file, base), stored);
      if (plain != null) how = 'verified';
    }
    plain ??= await encryptor.decryptBytesInBackground(stored);

    trace?.call(
      'offline-serve: ${p.basename(file.path)} ${stat.size}B $how read=${readMs}ms '
      '${how == 'verified' ? 'check' : 'decrypt'}=${watch.elapsedMilliseconds - readMs}ms '
      '(cipher so far: platform=${SnapshotEncryptor.nativeCalls} dart=${SnapshotEncryptor.dartCalls})',
    );
    if (epoch == _cacheEpoch) {
      _remember(_keyOf(file), _Plain(plain, stat.modified, stat.size));
    }
    return plain;
  }

  /// "assets/public/ikona.png": where [file] lives inside the page at [base],
  /// always with forward slashes (it is part of a checksum).
  static String _labelWithin(File file, Directory base) => p.posix.joinAll(
    p.split(p.relative(_keyOf(file), from: p.normalize(base.absolute.path))),
  );

  /// Puts what was JUST WRITTEN into memory, so that a page that has just been
  /// saved costs nothing to open: the plaintext was in hand a moment ago, and
  /// decrypting it again to learn what is already known is exactly the work this
  /// replaces. Silently ignored if the file is gone, or if the cache was
  /// emptied (sign-out, revocation) while this was waiting for the file system.
  Future<void> remember(File file, List<int> plaintext) async {
    final epoch = _cacheEpoch;
    try {
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return;
      if (epoch != _cacheEpoch) return;
      _remember(_keyOf(file), _Plain(plaintext, stat.modified, stat.size));
    } catch (_) {
      // A hint, never a reason to fail anything.
    }
  }

  void _remember(String path, _Plain entry) {
    final old = _plain.remove(path);
    if (old != null) _plainBytes -= old.bytes.length;
    if (entry.bytes.length > cacheLimitBytes) return; // too big to keep
    _plain[path] = entry;
    _plainBytes += entry.bytes.length;
    while (_plainBytes > cacheLimitBytes && _plain.isNotEmpty) {
      final oldest = _plain.keys.first;
      _plainBytes -= _plain.remove(oldest)!.bytes.length;
    }
  }

  /// Decrypts every file of a saved page ahead of time, a few at a time, so
  /// that the first request for it costs nothing. For the moment the copy is
  /// NOT needed: while the live page is loading, or just after it was saved.
  /// Best effort and silent.
  Future<void> prewarm(Directory pageDirectory) async {
    try {
      final files = <File>[];
      await for (final entity in pageDirectory.list(recursive: true, followLinks: false)) {
        // The manifest is read by the store, never served.
        if (entity is File && p.basename(entity.path) != 'manifest.json') files.add(entity);
      }
      // Largest first: the logo is the long pole, start it before the rest.
      final sizes = {for (final f in files) f.path: await f.length()};
      files.sort((a, b) => sizes[b.path]!.compareTo(sizes[a.path]!));
      for (var i = 0; i < files.length; i += 3) {
        await Future.wait(files.skip(i).take(3).map((f) => _plaintextOf(f, pageDirectory)));
      }
    } catch (_) {
      // Nothing depends on it.
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }

      if (!ownsUrl(request.requestedUri)) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final requestToken = _accessToken;
      final root = rootDirectory;
      if (root == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final file = _resolveWithinRoot(
        root,
        request.uri.path.substring(requestToken.length + 1),
      );
      if (file == null || !await file.exists()) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      // Offline-architecture milestone, P8.2: every file under `root` is
      // SnapshotStore-encrypted (see that class's own `encryptor` field)
      // — decrypted here, in memory, before a single byte reaches the
      // WebView. This is why this server reads the WHOLE file up front
      // rather than streaming it straight from disk the way the P2
      // version did: there is no way to decrypt an AEAD-sealed payload
      // incrementally without having all of it (the authentication tag
      // covers the complete ciphertext). Snapshot pages are HTML/CSS/JS/
      // images for a legacy admin panel, not multi-gigabyte media, so
      // buffering one complete file in memory per request is an
      // acceptable, deliberate trade-off for this specific content.
      final plain = await _plaintextOf(file, root);
      if (plain == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      var decryptedBytes = plain;
      if (requestToken != _accessToken || root != rootDirectory) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final type = _contentTypeFor(file.path);
      if (type.mimeType == 'text/html' || type.mimeType == 'text/css') {
        decryptedBytes = utf8.encode(
          utf8
              .decode(decryptedBytes)
              .replaceAll('/assets/', '/$requestToken/assets/'),
        );
      }

      response.statusCode = HttpStatus.ok;
      response.headers.contentType = type;
      response.headers.contentLength = decryptedBytes.length;
      // Review round: this is a point-in-time snapshot the app manages
      // itself — nothing upstream of this server (the WebView, any
      // platform HTTP cache) should ever serve a stale copy of a page
      // after the app has replaced it with a fresher snapshot.
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.set('Referrer-Policy', 'no-referrer');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      response.headers.set(
        'Content-Security-Policy',
        "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval'; "
            "style-src 'self' 'unsafe-inline'; connect-src 'none'; form-action 'none'; "
            "frame-src 'none'; object-src 'none'; base-uri 'none'",
      );

      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      response.add(decryptedBytes);
      await response.close();
    } catch (_) {
      // Never let one bad request (a half-closed socket, a file that
      // disappeared mid-read, ...) crash the server or hang the
      // connection open — best-effort 500, swallow any secondary error
      // from trying to even write that.
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {
        // Connection is already unusable — nothing left to do.
      }
    }
  }

  /// Resolves [requestPath] against [root], returning null if the
  /// result would fall OUTSIDE root after normalization — the single
  /// security-critical check in this class. Deliberately simple,
  /// manual string comparison rather than a package helper whose exact
  /// edge-case behavior this codebase hasn't independently verified.
  File? _resolveWithinRoot(Directory root, String requestPath) {
    var relative = requestPath;
    if (relative.startsWith('/')) {
      relative = relative.substring(1);
    }
    if (relative.isEmpty) {
      return null;
    }

    final rootCanonical = p.normalize(root.absolute.path);
    final targetCanonical = p.normalize(p.join(rootCanonical, relative));

    if (!_isWithin(rootCanonical, targetCanonical)) {
      return null;
    }

    return File(targetCanonical);
  }

  bool _isWithin(String rootCanonical, String targetCanonical) {
    if (targetCanonical == rootCanonical) {
      // The root directory itself is never servable — no directory
      // listing, see this class's own docblock.
      return false;
    }
    final rootWithSeparator = rootCanonical.endsWith(Platform.pathSeparator)
        ? rootCanonical
        : '$rootCanonical${Platform.pathSeparator}';
    return targetCanonical.startsWith(rootWithSeparator);
  }

  static const Map<String, String> _extensionToMimeType = {
    // Review round fix (real bug, caught by CI): snapshot PAGE files
    // keep their ORIGINAL legacy filename — /dashboard.php,
    // /public/schedule.php, etc. — because the whole point of this
    // server is serving them back at the SAME path the WebView already
    // knows. Their content is pure rendered HTML by the time they're
    // captured, so .php must map to text/html here, same as .html
    // itself — this was the one missing entry the test caught
    // (dashboard.php was falling through to the application/
    // octet-stream default, which a WebView won't render as a page).
    '.php': 'text/html',
    '.html': 'text/html',
    '.htm': 'text/html',
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.mjs': 'application/javascript',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
    '.otf': 'font/otf',
    '.eot': 'application/vnd.ms-fontobject',
    '.mp4': 'video/mp4',
    '.webm': 'video/webm',
    '.mp3': 'audio/mpeg',
    '.wav': 'audio/wav',
    '.txt': 'text/plain',
    '.xml': 'application/xml',
  };

  ContentType _contentTypeFor(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    final mimeType = _extensionToMimeType[ext];
    if (mimeType == null) {
      return ContentType('application', 'octet-stream');
    }

    final slash = mimeType.indexOf('/');
    final primary = mimeType.substring(0, slash);
    final sub = mimeType.substring(slash + 1);
    final isText =
        primary == 'text' ||
        mimeType == 'application/json' ||
        mimeType == 'application/xml';
    return ContentType(primary, sub, charset: isText ? 'utf-8' : null);
  }
}

class _Plain {
  const _Plain(this.bytes, this.modified, this.length);
  final List<int> bytes;
  final DateTime modified;
  final int length;
}
